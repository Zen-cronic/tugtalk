@preconcurrency import AVFoundation
import Combine
import Foundation
import OSLog
import ScreenContextCore

/// Records when a hands check was turned on, its clip's frame count and size, and the server's status. Never a frame.
let replayLog = Logger(subsystem: "com.kaungzinhein.commscoach.mac", category: "replay")

/// "Check what's in my hands this round". Off by default, and off again after every round: turned on from a reply
/// card, it starts with the next answer. While it is on, the frames the camera already reads for "faced the camera"
/// are also scaled into one silent clip for the round (`ReplayClipWriter`, at most 15 s). When the round's wrap-up
/// is saved, the clip goes to `POST /v1/voice-rounds/{id}/replay` and is deleted from this Mac; Meta's SAM 3.1 finds
/// hands, phones and paper, and the server keeps only the seconds code counted. Nothing is sent without the toggle.
@MainActor
final class ReplayCheck: ObservableObject {
    static let shared = ReplayCheck()

    enum Result: Equatable {
        case sending
        case counted(ReplayCounts)
        /// Plain words for the tooltip; the strip itself only says "Hands check unavailable".
        case unavailable(String)
    }

    /// On for the current round only.
    @Published private(set) var armed = false
    /// By round id: the wrap-up card shows the strip for its own round.
    @Published private(set) var results: [String: Result] = [:]

    private var writer: ReplayClipWriter?
    private var lastHold: Date?
    /// DEBUG `-replayFixtureMP4 <path>`: this file is sent instead of a clip from the camera, so no camera is needed.
    let fixture: URL?
    /// DEBUG `-replayArmed YES`: the check is on for every round, for scripted runs with no clicks.
    private let alwaysOn: Bool

    private static let folder: URL = FileManager.default.temporaryDirectory.appending(path: "CommsCoachReplay", directoryHint: .isDirectory)

    private init() {
        #if DEBUG
        fixture = UserDefaults.standard.string(forKey: "replayFixtureMP4").map { URL(fileURLWithPath: $0) }
        alwaysOn = UserDefaults.standard.bool(forKey: "replayArmed")
        #else
        fixture = nil
        alwaysOn = false
        #endif
        armed = alwaysOn
        // A clip left by a run that quit mid-round is deleted at launch.
        if let left = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil), !left.isEmpty {
            left.forEach { try? FileManager.default.removeItem(at: $0) }
            replayLog.notice("deleted \(left.count, privacy: .public) clip(s) left from an earlier run")
        }
    }

    /// The toggle is offered only when there are frames to send: the camera is on for practice, or a fixture stands in.
    var available: Bool { fixture != nil || CameraSettings.enabled }

    func setArmed(_ on: Bool) {
        armed = on
        if !on { discardClip() }
        replayLog.notice("hands check \(on ? "on" : "off", privacy: .public) for this round")
    }

    /// Key-down, as the camera opens: the clip writer for this hold's frames, or nil when the check is off.
    func sink(forHold key: String) -> ReplayClipWriter? {
        guard armed, fixture == nil else { return nil }
        // A long silence ends a round by itself (`RoundTally.idleGap`); its frames do not carry into the next.
        if let lastHold, Date().timeIntervalSince(lastHold) > RoundTally.idleGap { discardClip() }
        lastHold = Date()
        if writer == nil {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            writer = ReplayClipWriter(url: Self.folder.appending(path: "\(UUID().uuidString).mp4"))
        }
        guard let writer, !writer.isFull else { return nil }
        writer.beginSegment()
        return writer
    }

    /// The round's wrap-up was saved: send its clip once, if the check was on.
    func roundEnded(roundID: String) {
        guard armed, results[roundID] == nil else { return }
        let clip = writer
        writer = nil; lastHold = nil
        armed = alwaysOn
        results[roundID] = .sending
        Task { await send(roundID, clip: clip) }
    }

    /// The round was closed without a wrap-up: its frames are dropped and the check turns off.
    func roundAbandoned() {
        guard writer != nil || armed else { return }
        discardClip()
        armed = alwaysOn
    }

    private func discardClip() {
        writer?.cancel()
        writer = nil
        lastHold = nil
    }

    private func send(_ roundID: String, clip: ReplayClipWriter?) async {
        let started = Date()
        let data: Data, segments: [Range<Int>]
        do {
            if let fixture {
                data = try Data(contentsOf: fixture)
                segments = [0..<(try await Self.frameCount(fixture))]
            } else if let clip {
                let file = try await clip.finish()
                // Read into memory, then deleted at once: the clip is never kept on this Mac.
                defer { try? FileManager.default.removeItem(at: file.url) }
                data = try Data(contentsOf: file.url)
                segments = file.segments
            } else {
                throw ReplayClipError.noFrames
            }
        } catch {
            let why = (error as? ReplayClipError) == .noFrames ? "No camera frames this round." : "The clip could not be made."
            replayLog.notice("hands check not sent: \(why, privacy: .public)")
            results[roundID] = .unavailable(why)
            return
        }
        guard let api = Connection.api()?.api else { results[roundID] = .unavailable(Connection.unavailableReason); return }
        let frames = segments.last?.upperBound ?? 0
        replayLog.notice("sending hands check: \(frames, privacy: .public) frames, \(data.count, privacy: .public) bytes, \(segments.count, privacy: .public) answer(s)\(self.fixture == nil ? "" : " (fixture clip, camera not used)", privacy: .public)")
        let key = CoachAPI.newIdempotencyKey(prefix: "mac-replay")
        for attempt in 1...2 {
            do {
                let receipt = try await api.sendReplay(roundID: roundID, clip: data, segments: segments, idempotencyKey: key)
                results[roundID] = .counted(receipt.replay)
                replayLog.notice("hands check counted in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
                return
            } catch let error as CoachError where error.isRetryable && attempt == 1 {
                try? await Task.sleep(for: .seconds(1))
            } catch {
                let status: String = if case .server(let code, let name, _) = error as? CoachError { "\(code) \(name)" } else { "offline" }
                replayLog.notice("hands check unavailable (\(status, privacy: .public))")
                results[roundID] = .unavailable((error as? CoachError)?.plainMessage(for: .voiceReply) ?? "The coach could not be reached.")
                return
            }
        }
    }

    private static func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return min(ReplayClip.maxFrames, max(1, Int((duration.seconds * Double(ReplayClip.fps)).rounded())))
    }
}
