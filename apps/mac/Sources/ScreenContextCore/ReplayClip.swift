@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The hands check's clip: the frames the camera already reads during a round's holds, written as one silent MP4
/// (H.264, at most 640×360 with the camera's shape kept, 10 frames a second, at most 150 frames, faststart).
/// Only made when the person turned the check on for that round, and deleted once it is sent.
public enum ReplayClip {
    public static let fps: Int32 = 10
    public static let maxFrames = 150
    public static let maxWidth = 640
    public static let maxHeight = 360
    /// The server's body limit (`REPLAY_MAX_BYTES`, deploy/bridge.py `VIDEO_LIMIT`).
    public static let maxBytes = 1024 * 1024
    /// About 300 kbit/s: 15 s is about 560 KB, under the 1 MiB limit with room to spare.
    public static let bitRate = 300_000

    /// The clip size for a camera frame: the camera's shape, scaled down to fit 640×360, even sides.
    public static func size(forWidth width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(1, min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height)))
        let even = { (v: Double) in max(2, Int(v.rounded(.down)) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// `X-Replay-Segments`: each hold's frames, "start-end" with end exclusive, for example "0-42,42-97".
    public static func segmentsHeader(_ segments: [Range<Int>]) -> String {
        segments.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
    }
}

/// A finished clip on disk, ready to send. The caller deletes `url` once it is sent.
public struct ReplayClipFile: Sendable, Equatable {
    public let url: URL
    public let frames: Int
    /// Each hold's frames in the clip, in order.
    public let segments: [Range<Int>]
    public let bytes: Int
}

public enum ReplayClipError: Error, Equatable { case noFrames, writerFailed(String), tooLarge(Int) }

/// Writes frames from the camera's queue into one MP4. Thread-safe through its lock. Presentation times run on across
/// holds (frame n is shown at n/10 s), so the gaps between answers are not in the clip. It stops taking frames at 150.
public final class ReplayClipWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var transfer: VTPixelTransferSession?
    private var frames = 0
    private var segmentStarts: [Int] = []
    private var finished = false
    private var failure: String?

    public init(url: URL) { self.url = url }

    public var frameCount: Int { lock.withLock { frames } }
    public var isFull: Bool { lock.withLock { frames >= ReplayClip.maxFrames } }

    /// A new hold starts: its frames form the next segment.
    public func beginSegment() {
        lock.withLock {
            guard !finished, frames < ReplayClip.maxFrames else { return }
            if segmentStarts.last != frames { segmentStarts.append(frames) }
        }
    }

    /// One frame the camera read. Scaled into the clip's own buffer at once, so the camera's buffer is not kept.
    /// Returns false when the frame was not taken (the clip is full, finished or failed).
    @discardableResult
    public func append(_ pixels: CVPixelBuffer) -> Bool {
        lock.withLock {
            guard !finished, failure == nil, frames < ReplayClip.maxFrames else { return false }
            if writer == nil { start(CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels)) }
            guard let input, let adaptor, let transfer, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return false }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
                  VTPixelTransferSessionTransferImage(transfer, from: pixels, to: out) == noErr else { return false }
            if segmentStarts.isEmpty { segmentStarts.append(0) }
            guard adaptor.append(out, withPresentationTime: CMTime(value: CMTimeValue(frames), timescale: ReplayClip.fps)) else {
                failure = writer?.error?.localizedDescription ?? "append failed"
                return false
            }
            frames += 1
            return true
        }
    }

    private func start(_ width: Int, _ height: Int) {
        let size = ReplayClip.size(forWidth: width, height: height)
        do {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true // moov first (faststart)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: ReplayClip.bitRate, AVVideoMaxKeyFrameIntervalKey: Int(ReplayClip.fps),
                                                  AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel]])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
            guard writer.canAdd(input) else { failure = "cannot add video"; return }
            writer.add(input)
            guard writer.startWriting() else { failure = writer.error?.localizedDescription ?? "cannot start"; return }
            writer.startSession(atSourceTime: .zero)
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { failure = "no scaler"; return }
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            self.writer = writer; self.input = input; self.adaptor = adaptor; self.transfer = session
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Ends the clip and returns it. Throws (and deletes any partial file) when nothing was written or writing failed.
    public func finish() async throws -> ReplayClipFile {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReplayClipFile, Error>) in
            finish { continuation.resume(with: $0) }
        }
    }

    /// The same, with a completion handler (called once, on any thread).
    public func finish(_ done: @escaping @Sendable (Result<ReplayClipFile, Error>) -> Void) {
        lock.lock()
        finished = true
        nonisolated(unsafe) let writer = self.writer
        let input = self.input, count = frames, starts = segmentStarts, failure = self.failure
        lock.unlock()
        guard let writer, let input, count > 0, failure == nil else {
            writer?.cancelWriting()
            discard()
            done(.failure(failure.map { ReplayClipError.writerFailed($0) } ?? ReplayClipError.noFrames))
            return
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: ReplayClip.fps))
        let url = self.url
        writer.finishWriting { [self] in
            // Read back through this (lock-protected) instance, so the writer itself is not captured.
            let (status, error) = lock.withLock { (self.writer?.status ?? .failed, self.writer?.error?.localizedDescription) }
            guard status == .completed else {
                discard()
                done(.failure(ReplayClipError.writerFailed(error ?? "status \(status.rawValue)")))
                return
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let bounds = starts.filter { $0 < count } + [count]
            let segments = zip(bounds, bounds.dropFirst()).map { $0..<$1 }.filter { !$0.isEmpty }
            if bytes > ReplayClip.maxBytes { discard(); done(.failure(ReplayClipError.tooLarge(bytes))); return }
            done(.success(ReplayClipFile(url: url, frames: count, segments: segments, bytes: bytes)))
        }
    }

    /// Stops and deletes the file. Used when the round is left without a wrap-up.
    public func cancel() {
        let writer: AVAssetWriter? = lock.withLock { finished = true; return self.writer }
        if writer?.status == .writing { writer?.cancelWriting() }
        discard()
    }

    private func discard() { try? FileManager.default.removeItem(at: url) }
}

// Response shapes

public struct ReplaySeconds: Decodable, Sendable, Equatable {
    public let phone_in_hand: Double
    public let paper_in_hand: Double

    public init(phone_in_hand: Double, paper_in_hand: Double) { self.phone_in_hand = phone_in_hand; self.paper_in_hand = paper_in_hand }
}

public struct ReplaySecond: Decodable, Sendable, Equatable {
    public let frames: Int
    public let phone_in_hand: Int
    public let paper_in_hand: Int
    /// Frames in this second with a phone or a paper in hand.
    public let in_hand: Int

    public init(frames: Int, phone_in_hand: Int, paper_in_hand: Int, in_hand: Int) {
        self.frames = frames; self.phone_in_hand = phone_in_hand; self.paper_in_hand = paper_in_hand; self.in_hand = in_hand
    }
}

public struct ReplayCounts: Decodable, Sendable, Equatable {
    public let method: String
    public let fps: Int
    public let frames: Int
    public let seconds: ReplaySeconds
    public let per_second: [ReplaySecond]

    public init(method: String, fps: Int, frames: Int, seconds: ReplaySeconds, per_second: [ReplaySecond]) {
        self.method = method; self.fps = fps; self.frames = frames; self.seconds = seconds; self.per_second = per_second
    }

    /// "phone in hand 3 s", "paper in hand 2.4 s", both joined, or "no phone or paper in hand". Counted objects only.
    public var label: String {
        let parts = [("phone", seconds.phone_in_hand), ("paper", seconds.paper_in_hand)].filter { $0.1 > 0 }
            .map { "\($0.0) in hand \(Self.seconds($0.1))" }
        return parts.isEmpty ? "no phone or paper in hand" : parts.joined(separator: ", ")
    }

    /// "3 s" for whole seconds, else one decimal ("2.8 s").
    public static func seconds(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))\u{00A0}s" : String(format: "%.1f\u{00A0}s", tenths / 10)
    }

    /// Each second's share of frames with something in hand, 0...1, one per second of the clip.
    public var cells: [Double] { per_second.map { $0.frames > 0 ? min(1, Double($0.in_hand) / Double($0.frames)) : 0 } }
}

public struct ReplayReceipt: Decodable, Sendable, Equatable {
    public let round_id: String
    public let receipt_id: String
    public let replayed: Bool
    public let replay: ReplayCounts
}

extension CoachAPI {
    /// The hands check for a round that just ended. Keep `idempotencyKey` for a retry: it never pays twice.
    public func sendReplay(roundID: String, clip: Data, segments: [Range<Int>], idempotencyKey: String) async throws -> ReplayReceipt {
        var request = request("v1/voice-rounds/\(roundID)/replay", method: "POST", timeout: 60)
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(ReplayClip.segmentsHeader(segments), forHTTPHeaderField: "X-Replay-Segments")
        request.httpBody = clip
        return try await send(request, as: ReplayReceipt.self)
    }
}
