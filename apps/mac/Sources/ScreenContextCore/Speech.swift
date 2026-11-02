import Foundation

/// The question to say out loud, and the round it belongs to (the server voices that round's reply).
public struct SpokenLine: Sendable, Equatable {
    public let text: String
    public let language: VoiceLanguage
    public let roundID: String?

    public init(text: String, language: VoiceLanguage, roundID: String?) {
        self.text = text; self.language = language; self.roundID = roundID
    }
}

/// What a speaker reports. After `started` (with the voice's name, if it has one), exactly one of
/// `finished` or `failed`; nothing after `stop()`.
public struct SpeechEvents {
    public let started: @MainActor (String?) -> Void
    public let finished: @MainActor (Date) -> Void
    public let failed: @MainActor (Error) -> Void

    public init(started: @escaping @MainActor (String?) -> Void, finished: @escaping @MainActor (Date) -> Void, failed: @escaping @MainActor (Error) -> Void) {
        self.started = started; self.finished = finished; self.failed = failed
    }
}

/// One way to say a question out loud: the coach server's voice, or Apple's voice on this Mac.
@MainActor
public protocol ReplySpeaker: AnyObject {
    func speak(_ line: SpokenLine, events: SpeechEvents)
    /// Stops at once, mid-word, and reports nothing more for that line.
    func stop()
}

/// Which voice said the question.
public enum SpeechSource: Equatable, Sendable {
    /// The coach server's voice; `provider` is its `X-Speech-Provider` header, if sent.
    case remote(provider: String?)
    case fallback(reason: String)

    /// For the card: which voice spoke.
    public var label: String {
        switch self {
        case .remote(let provider):
            switch provider?.lowercased() {
            case "wit": "Wit.ai voice, through the coach"
            case "mms": "Meta MMS-TTS voice, through the coach"
            case "elevenlabs": "ElevenLabs voice, through the coach"
            default: "The coach's voice"
            }
        case .fallback(let reason): "Fallback voice on this Mac: \(reason)"
        }
    }
}

/// Tries the remote voice first and falls back to the local one when it fails before any audio
/// plays (no voice key on the server, the network, or more than 2 s to the first audio).
/// `stop()` silences both, for barge-in.
@MainActor
public final class SpeechRouter {
    private let remote: ReplySpeaker?
    private let fallback: ReplySpeaker
    private var generation = 0
    public private(set) var isSpeaking = false

    private let localReason: String

    /// `remote` nil means the local voice only; `localReason` is then the card's note for it.
    public init(remote: ReplySpeaker?, fallback: ReplySpeaker, localReason: String = "no round to voice") {
        self.remote = remote; self.fallback = fallback; self.localReason = localReason
    }

    public func speak(_ line: SpokenLine, started: @escaping @MainActor (SpeechSource) -> Void, finished: @escaping @MainActor (Date) -> Void) {
        stop()
        generation += 1
        let current = generation
        isSpeaking = true
        let live = { [weak self] in self?.generation == current }
        let done: @MainActor (Date) -> Void = { [weak self] ended in
            guard live() else { return }
            self?.isSpeaking = false
            finished(ended)
        }
        let viaFallback: @MainActor (String) -> Void = { [weak self] reason in
            guard live(), let self else { return }
            self.fallback.speak(line, events: SpeechEvents(
                started: { _ in if live() { started(.fallback(reason: reason)) } },
                finished: done,
                // The local voice failing too leaves nothing to say; treat the question as ended.
                failed: { _ in done(Date()) }))
        }
        guard let remote, line.roundID != nil else {
            viaFallback(remote == nil ? localReason : "no round to voice")
            return
        }
        remote.speak(line, events: SpeechEvents(
            started: { provider in if live() { started(.remote(provider: provider)) } },
            finished: done,
            failed: { error in viaFallback(Self.reason(for: error)) }))
    }

    /// Barge-in or a closed card: both voices stop, and late events from either are ignored.
    public func stop() {
        generation += 1
        isSpeaking = false
        remote?.stop()
        fallback.stop()
    }

    /// A short reason for the card's "fallback voice" note.
    public nonisolated static func reason(for error: Error) -> String {
        switch error {
        case SpeechFetchError.timedOut: "the coach voice took over 2 s to start"
        case CoachError.server(503, "speech_unconfigured", _): "the coach has no voice set up"
        case CoachError.server(let status, _, _): "the coach voice failed (\(status))"
        case CoachError.offline: "the coach voice could not be reached"
        default: "the coach voice could not play"
        }
    }
}

public enum SpeechFetchError: Error, Equatable {
    case timedOut
    case notAudio(String)
    /// Raw PCM has no header to say its rate, so it cannot be played as a file.
    case unplayable(String)
    case empty
}

/// A spoken question from the coach server: the audio file and which voice made it.
public struct SpeechAudio: Sendable, Equatable {
    public let data: Data
    public let contentType: String
    public let provider: String?
    public let voice: String?

    /// `true` for WAV, `false` for MP3, as a hint to the player.
    public var isWAV: Bool { contentType.contains("wav") }
}

extension CoachAPI {
    /// The round's question as audio from `POST /v1/voice-rounds/{round_id}/speech` (WAV or MP3, possibly
    /// chunked). Fails if no audio byte arrives within `firstAudio`, or the whole clip takes longer than `total`.
    /// The speech provider's key stays on the server; this Mac only ever sees the audio.
    public func fetchSpeech(roundID: String, firstAudio: Duration = .seconds(2), total: Duration = .seconds(12)) async throws -> SpeechAudio {
        var request = request("v1/voice-rounds/\(roundID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? roundID)/speech",
                              method: "POST", timeout: 15)
        request.setValue("audio/wav, audio/mpeg", forHTTPHeaderField: "Accept")
        let speechRequest = request
        let gotFirstByte = OnceFlag()
        return try await withThrowingTaskGroup(of: SpeechAudio.self) { group in
            group.addTask { try await downloadAudio(speechRequest, firstByte: gotFirstByte) }
            group.addTask {
                try await Task.sleep(for: firstAudio)
                if !gotFirstByte.isSet { throw SpeechFetchError.timedOut }
                try await Task.sleep(for: total - firstAudio)
                throw SpeechFetchError.timedOut
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw SpeechFetchError.empty }
            return data
        }
    }

    private func downloadAudio(_ request: URLRequest, firstByte: OnceFlag) async throws -> SpeechAudio {
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoachError.offline("The coach voice can't be reached.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var data = Data()
        do {
            for try await byte in bytes {
                if data.isEmpty && (200..<300).contains(status) { firstByte.set() }
                data.append(byte)
            }
        } catch is CancellationError { throw CancellationError() } catch {
            throw CoachError.offline("The coach voice stopped mid-way.")
        }
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw CoachError.server(status, body?.error ?? "error", body?.message ?? "Speech failed")
        }
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard type.hasPrefix("audio/") else { throw SpeechFetchError.notAudio(type) }
        guard ["audio/wav", "audio/x-wav", "audio/wave", "audio/mpeg", "audio/mp3"].contains(type) else { throw SpeechFetchError.unplayable(type) }
        guard !data.isEmpty else { throw SpeechFetchError.empty }
        return SpeechAudio(data: data, contentType: type, provider: http?.value(forHTTPHeaderField: "X-Speech-Provider"),
                           voice: http?.value(forHTTPHeaderField: "X-Speech-Voice"))
    }
}

private struct ErrorBody: Decodable { let error: String; let message: String? }

/// Set once from the download task, read by the timer task.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
