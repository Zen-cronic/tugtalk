import Foundation

/// The live voice round (`WS /v1/voice-rounds/live`): while ⌃⌥T is held, the samples go to the coach as they are
/// recorded, and Meta transcribes them as they arrive. On release the reply comes back as an event, its audio follows
/// on the same socket, and `saved` arrives once the round is committed. One socket per hold.

/// The start frame: what a WAV round sends in headers. The same key, samples and values make the same round, so a
/// fallback upload of this hold with this key replays the live round if it was saved.
public struct LiveStart: Sendable, Equatable, Encodable {
    public let type = "start"
    public var idempotency_key: String
    public var language: String
    public var goal_id: String?
    public var screen_context_id: String?
    public var prompt_ended_at: String?
    public var occurred_at: String?
    /// False when this Mac speaks the reply itself: the coach then makes no audio.
    public var speech: Bool

    public init(_ round: VoiceRoundRequest, speech: Bool = true) {
        self.speech = speech
        idempotency_key = round.idempotencyKey; language = round.language.rawValue; goal_id = round.goalID; screen_context_id = round.screenContextID
        prompt_ended_at = round.promptEndedAt.map(VoiceRoundRequest.timestamp); occurred_at = round.occurredAt.map(VoiceRoundRequest.timestamp)
    }
}

public struct LiveLatency: Decodable, Sendable, Equatable {
    public let asr: Double?
    public let model: Double?
    public let release_to_reply: Double?
}

/// The checked reply, before it is saved.
public struct LiveReply: Decodable, Sendable, Equatable {
    public let round_id: String
    public let transcript: String
    public let metrics: VoiceMetrics?
    public let reply: VoiceReply
    public let model: String
    public let provider_request_id: String?
    public let latency_ms: LiveLatency?
    public let transcription: String?
}

public enum LiveVoiceEvent: Sendable, Equatable {
    case ready(transcription: String)
    case partial(String)
    case transcript(String, mode: String)
    case reply(LiveReply)
    case speechStart(contentType: String, provider: String?)
    case speechUnavailable(String)
    case audio(Data)
    case speechEnd
    case saved(VoiceRoundReceipt)
    case error(CoachError)
    /// The socket closed; `code` is the WebSocket close code (nil when it failed instead).
    case closed(code: Int?)

    /// Parses one text frame; nil for an event this build does not know (newer servers stay compatible).
    public static func decode(_ text: String) -> LiveVoiceEvent? {
        let data = Data(text.utf8)
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { return nil }
        let d = JSONDecoder()
        switch head.type {
        case "ready": return .ready(transcription: head.transcription ?? "realtime")
        case "partial": return .partial(head.text ?? "")
        case "transcript": return .transcript(head.text ?? "", mode: head.transcription ?? "realtime")
        case "reply": return (try? d.decode(LiveReply.self, from: data)).map(LiveVoiceEvent.reply)
        case "speech_start": return .speechStart(contentType: head.content_type ?? "audio/mpeg", provider: head.provider)
        case "speech_unavailable": return .speechUnavailable(head.error ?? "speech_unconfigured")
        case "speech_end": return .speechEnd
        case "saved": return (try? d.decode(VoiceRoundReceipt.self, from: data)).map(LiveVoiceEvent.saved)
        case "error": return .error(.server(head.status ?? 503, head.error ?? "error", head.message ?? "The coach couldn't reply."))
        default: return nil
        }
    }

    private struct Head: Decodable {
        let type: String
        let text: String?, transcription: String?, content_type: String?, provider: String?
        let error: String?, message: String?, status: Int?
    }
}

/// The socket, so the session can be tested without a network.
public protocol LiveSocket: AnyObject, Sendable {
    func sendText(_ text: String)
    func sendData(_ data: Data)
    /// Every frame from the server, then `.closed`.
    var incoming: AsyncStream<LiveSocketFrame> { get }
    func close()
}

public enum LiveSocketFrame: Sendable { case text(String), data(Data), closed(Int?) }

/// URLSessionWebSocketTask with the connector key in the upgrade request. Sends keep their order.
public final class URLSessionLiveSocket: LiveSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    public let incoming: AsyncStream<LiveSocketFrame>
    private let continuation: AsyncStream<LiveSocketFrame>.Continuation

    public init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2 * 1024 * 1024
        (incoming, continuation) = AsyncStream.makeStream(of: LiveSocketFrame.self)
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)): self.continuation.yield(.text(text)); self.receive()
            case .success(.data(let data)): self.continuation.yield(.data(data)); self.receive()
            case .success: self.receive()
            case .failure:
                let code = self.task.closeCode == .invalid ? nil : self.task.closeCode.rawValue
                self.continuation.yield(.closed(code)); self.continuation.finish()
            }
        }
    }

    public func sendText(_ text: String) { task.send(.string(text)) { _ in } }
    public func sendData(_ data: Data) { task.send(.data(data)) { _ in } }
    public func close() { task.cancel(with: .normalClosure, reason: nil) }
}

extension CoachAPI {
    /// The live route on the same host as every other request: https becomes wss, http (local tests) becomes ws.
    public var liveURL: URL {
        var parts = URLComponents(url: baseURL.appending(path: "v1/voice-rounds/live"), resolvingAgainstBaseURL: false)!
        parts.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        return parts.url!
    }

    public func liveSocket() -> URLSessionLiveSocket {
        var request = URLRequest(url: liveURL)
        request.timeoutInterval = 15
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return URLSessionLiveSocket(request: request, session: session)
    }
}

/// One hold over a live socket: the start frame at once, then samples as they are recorded, then "end".
/// `events` yields the decoded events and the reply's audio, then `.closed`.
public final class LiveVoiceSession: @unchecked Sendable {
    private let socket: LiveSocket
    private let lock = NSLock()
    private var ended = false
    private var sentSamples = 0
    public let events: AsyncStream<LiveVoiceEvent>

    public init(socket: LiveSocket, start: LiveStart) {
        self.socket = socket
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        socket.sendText(String(decoding: (try? encoder.encode(start)) ?? Data(), as: UTF8.self))
        events = AsyncStream { continuation in
            let reader = Task {
                for await frame in socket.incoming {
                    switch frame {
                    case .text(let text): if let event = LiveVoiceEvent.decode(text) { continuation.yield(event) }
                    case .data(let data): continuation.yield(.audio(data))
                    case .closed(let code): continuation.yield(.closed(code: code))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// Samples as recorded (24 kHz mono Int16), from any thread; sent in call order. Ignored after `end()`.
    public func send(_ samples: ArraySlice<Int16>) {
        lock.withLock {
            guard !ended, !samples.isEmpty else { return }
            sentSamples += samples.count
            socket.sendData(Self.littleEndian(samples))
        }
    }

    /// The key was released: no more samples. The hold's camera numbers, when the camera was on, ride on the same frame.
    public func end(camera: CameraMetrics? = nil) {
        lock.withLock {
            guard !ended else { return }
            ended = true
            socket.sendText(camera.map { #"{"camera":\#($0.headerValue),"type":"end"}"# } ?? #"{"type":"end"}"#)
        }
    }

    public var samplesSent: Int { lock.withLock { sentSamples } }

    /// Closes the socket: before `end()` the server drops the hold; after it, the round is still saved.
    public func close() {
        lock.withLock { ended = true }
        socket.close()
    }

    public static func littleEndian(_ samples: ArraySlice<Int16>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
}
