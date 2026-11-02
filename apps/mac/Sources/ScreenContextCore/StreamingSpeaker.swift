import Foundation

/// A spoken reply as it arrives: its type, which voice made it, and its bytes in order.
public struct SpeechStream: Sendable {
    public let contentType: String
    public let provider: String?
    public let chunks: AsyncThrowingStream<Data, Error>

    public init(contentType: String, provider: String?, chunks: AsyncThrowingStream<Data, Error>) {
        self.contentType = contentType; self.provider = provider; self.chunks = chunks
    }
}

/// Plays the coach's voice as it downloads. `open` finds the round's audio (the live socket's, or
/// `POST /v1/voice-rounds/{id}/speech`). If no sound has started `firstAudio` after `speak`, it gives up and
/// reports `failed(.timedOut)`, so the router speaks with the Mac's own voice. A stream that breaks after sound
/// began plays what arrived and ends. `stop()` silences it at once and reports nothing more.
@MainActor
public final class StreamingSpeaker: ReplySpeaker {
    public typealias Open = @Sendable (SpokenLine) async throws -> SpeechStream

    private let open: Open
    private let firstAudio: Duration
    private let volume: @MainActor () -> Float
    private var generation = 0
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var player: StreamingAudioPlayer?
    /// Called with the time from `speak` to the first sound, for the logs.
    public var onStarted: (TimeInterval, String?) -> Void = { _, _ in }

    public init(firstAudio: Duration = .seconds(2), volume: @escaping @MainActor () -> Float = { 1 }, open: @escaping Open) {
        self.open = open; self.firstAudio = firstAudio; self.volume = volume
    }

    // The line being spoken; replaced by each speak() and cleared by stop(), so late events are ignored.
    private var events: SpeechEvents?
    private var started = false
    private var asked = Date()
    private var provider: String?

    public func speak(_ line: SpokenLine, events: SpeechEvents) {
        stop()
        generation += 1
        let current = generation
        self.events = events
        started = false
        asked = Date()
        timer = Task { [weak self, firstAudio] in
            try? await Task.sleep(for: firstAudio)
            guard !Task.isCancelled, let self, self.generation == current, !self.started else { return }
            self.task?.cancel()
            self.end(current, .failure(SpeechFetchError.timedOut))
        }
        let open = self.open, volume = self.volume()
        task = Task { [weak self] in
            do {
                let stream = try await open(line)
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.provider = stream.provider
                guard let player = StreamingAudioPlayer(contentType: stream.contentType, volume: volume, onEvent: { [weak self] event in
                    MainActor.assumeIsolated { self?.playerEvent(event, current, type: stream.contentType) }
                }) else { throw SpeechFetchError.unplayable(stream.contentType) }
                self.player = player
                do {
                    for try await chunk in stream.chunks {
                        try Task.checkCancellation()
                        player.append(chunk)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Cut short before any sound: the router falls back. After some: play what arrived.
                    if !self.started { self.end(current, .failure(error)); return }
                }
                guard self.generation == current else { return }
                player.finish()
            } catch is CancellationError {
                return
            } catch {
                self?.end(current, .failure(error))
            }
        }
    }

    private func playerEvent(_ event: StreamingAudioPlayer.Event, _ current: Int, type: String) {
        guard generation == current else { return }
        switch event {
        case .started:
            started = true
            timer?.cancel()
            onStarted(Date().timeIntervalSince(asked), provider)
            events?.started(provider)
        case .finished: end(current, .success(Date()))
        case .failed: end(current, .failure(started ? SpeechFetchError.empty : SpeechFetchError.unplayable(type)))
        }
    }

    private func end(_ current: Int, _ result: Result<Date, Error>) {
        guard generation == current, let events else { return }
        self.events = nil
        timer?.cancel()
        switch result {
        case .success(let at): events.finished(at)
        case .failure(let error): player?.stop(); player = nil; events.failed(error)
        }
    }

    public func stop() {
        generation += 1
        events = nil
        task?.cancel(); task = nil
        timer?.cancel(); timer = nil
        player?.stop(); player = nil
    }
}

extension CoachAPI {
    /// `POST /v1/voice-rounds/{round_id}/speech` as a stream: returns once the headers say it is audio, then yields the
    /// bytes as they arrive (in runs of at most 512 bytes, so playback can start on the first ones).
    public func streamSpeech(roundID: String) async throws -> SpeechStream {
        var request = request("v1/voice-rounds/\(roundID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? roundID)/speech",
                              method: "POST", timeout: 15)
        request.setValue("audio/mpeg, audio/wav", forHTTPHeaderField: "Accept")
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoachError.offline("The coach voice can't be reached.")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 4096 { break } }
            let error = try? JSONDecoder().decode(SpeechErrorBody.self, from: body)
            throw CoachError.server(status, error?.error ?? "error", error?.message ?? "Speech failed")
        }
        let type = http?.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard type.hasPrefix("audio/") else { throw SpeechFetchError.notAudio(type) }
        guard ["audio/wav", "audio/x-wav", "audio/wave", "audio/mpeg", "audio/mp3"].contains(type) else { throw SpeechFetchError.unplayable(type) }
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let reader = Task {
                var run = Data()
                do {
                    for try await byte in bytes {
                        run.append(byte)
                        if run.count >= 512 { continuation.yield(run); run = Data() }
                    }
                    if !run.isEmpty { continuation.yield(run) }
                    continuation.finish()
                } catch {
                    if !run.isEmpty { continuation.yield(run) }
                    continuation.finish(throwing: CoachError.offline("The coach voice stopped mid-way."))
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return SpeechStream(contentType: type, provider: http?.value(forHTTPHeaderField: "X-Speech-Provider"), chunks: chunks)
    }
}

private struct SpeechErrorBody: Decodable { let error: String; let message: String? }
