import Foundation

/// One live reply's audio, from the socket to the speaker: it waits for the head (its type and voice), then hands over
/// the bytes as they arrive. Fails if the coach says it has no voice, or if the audio ends before it began, so the
/// Mac's voice speaks instead. Every caller waiting in `stream()` is resumed exactly once.
@MainActor
public final class LiveAudio {
    /// The server voice's source looks a round's live audio up here first (set by the voice flow).
    public static var lookup: (@MainActor (String) -> LiveAudio?)?

    /// The socket ended the reply's audio before any of it began (no `speech_start`).
    public struct EndedBeforeAudio: Error, Equatable {}

    private var head: (type: String, provider: String?)?
    private var failure: Error?
    private var waiters: [CheckedContinuation<SpeechStream, Error>] = []
    private let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init() { (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self) }

    /// Callers waiting for the head; for tests.
    var waiting: Int { waiters.count }

    private var speechStream: SpeechStream? { head.map { SpeechStream(contentType: $0.type, provider: $0.provider, chunks: chunks) } }

    public func start(contentType: String, provider: String?) {
        guard head == nil, failure == nil else { return }
        head = (contentType, provider)
        let stream = speechStream!
        let ready = waiters; waiters = []
        ready.forEach { $0.resume(returning: stream) }
    }

    public func yield(_ data: Data) { continuation.yield(data) }

    /// The audio is complete. If it never began, waiting callers fail rather than wait for ever.
    public func finish() {
        guard head == nil, failure == nil else { continuation.finish(); return }
        fail(EndedBeforeAudio())
    }

    public func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        continuation.finish(throwing: error)
        let waiting = waiters; waiters = []
        waiting.forEach { $0.resume(throwing: error) }
    }

    public func stream() async throws -> SpeechStream {
        if let stream = speechStream { return stream }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}
