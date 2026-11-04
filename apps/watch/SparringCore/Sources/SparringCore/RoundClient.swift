import Foundation

/// Why a turn could not get its reply, in the words the watch shows. `retryable` decides whether the screen
/// offers Retry, which resends the same recording with the same Idempotency-Key.
public struct RoundFailure: Error, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case offline, notSignedIn, rateLimited, serverError, unusableAudio, notSetUp, noQuestion, micOff, tooShort, unreadable
    }

    public let kind: Kind
    public let message: String
    public let status: Int?
    /// The error body's `error` code, when the server sent one (for example `screen_context_not_found`).
    public let code: String?

    public init(kind: Kind, message: String, status: Int? = nil, code: String? = nil) {
        self.kind = kind; self.message = message; self.status = status; self.code = code
    }

    /// The screen card sent with the answer is gone (hidden on the Mac, or deleted). Any other 404, such as a deleted
    /// goal, is not this.
    public var screenCardGone: Bool { status == 404 && code == "screen_context_not_found" }

    /// Network drops and 5xx are worth resending; the hourly limit, a refused key or bad audio are not.
    public var retryable: Bool { [.offline, .serverError, .unreadable].contains(kind) }

    public static let offline = RoundFailure(kind: .offline, message: "Lost connection.")
    public static let notSignedIn = RoundFailure(kind: .notSignedIn, message: "Add the connector key in Secrets.xcconfig and rebuild.")
    public static let micOff = RoundFailure(kind: .micOff, message: "Microphone access is off. Enable it in Settings.")
    public static let tooShort = RoundFailure(kind: .tooShort, message: "That was too short to send. Tap Record and answer out loud.")
    public static let noQuestion = RoundFailure(kind: .noQuestion, message: "The reply had no question to ask.")
    public static let unreadable = RoundFailure(kind: .unreadable, message: "The reply could not be read.")

    /// From an HTTP status and the error body's `error` and `message`.
    public static func from(status: Int, code: String?, message: String?) -> RoundFailure {
        let failure = classify(status: status, code: code, message: message)
        return RoundFailure(kind: failure.kind, message: failure.message, status: status, code: code)
    }

    private static func classify(status: Int, code: String?, message: String?) -> RoundFailure {
        switch (status, code) {
        case (401, _), (403, _): return RoundFailure(kind: .notSignedIn, message: "The coach refused the connector key.", status: status)
        case (429, _): return RoundFailure(kind: .rateLimited, message: "\(message ?? "Too many voice rounds this hour.") Try again later.", status: status)
        case (413, _): return RoundFailure(kind: .unusableAudio, message: "That was too long. Keep an answer under 3 minutes.", status: status)
        case (400, _), (415, _): return RoundFailure(kind: .unusableAudio, message: "The coach couldn't use that recording: \(message ?? "bad audio").", status: status)
        case (503, "reply_unconfigured"): return RoundFailure(kind: .notSetUp, message: "Voice replies are not set up on this coach yet.", status: status)
        case (let s, _) where s >= 500: return RoundFailure(kind: .serverError, message: "The coach couldn't reply just now.", status: status)
        default: return RoundFailure(kind: .serverError, message: message ?? "Request failed (\(status)).", status: status)
        }
    }

    public static func from(_ error: Error) -> RoundFailure {
        if let failure = error as? RoundFailure { return failure }
        if error is URLError { return .offline }
        return .unreadable
    }
}

private struct ErrorBody: Decodable { let error: String; let message: String? }

/// Where a turn's spoken question came from, for the small line under it.
public enum SpeechVoice: Sendable, Equatable {
    /// The coach server's voice; `provider` is its `X-Speech-Provider` header ("wit").
    case coach(provider: String?)
    /// The watch's own voice, and why.
    case watch(reason: String)

    public var label: String {
        switch self {
        case .coach(let provider): provider?.lowercased() == "wit" ? "Wit.ai voice, through the coach" : "The coach's voice"
        case .watch(let reason): "Watch voice: \(reason)"
        }
    }
}

/// A spoken question from the coach server.
public struct SpeechClip: Sendable, Equatable {
    public let data: Data
    public let contentType: String
    public let provider: String?
}

/// Sends a turn and fetches its spoken question. Network failures and 5xx are retried with the same
/// Idempotency-Key (at most `maxAttempts` sends); anything else is returned at once.
public struct RoundClient: Sendable {
    public let requests: RoundRequests
    public let session: URLSession
    public let maxAttempts: Int
    public let backoff: @Sendable (Int) -> Duration

    public init(requests: RoundRequests, session: URLSession = .shared, maxAttempts: Int = 3,
                backoff: @escaping @Sendable (Int) -> Duration = { .milliseconds(600 * $0) }) {
        self.requests = requests; self.session = session; self.maxAttempts = max(1, maxAttempts); self.backoff = backoff
    }

    public func send(_ upload: AnswerUpload, wav: Data) async throws -> VoiceRoundReceipt {
        var attempt = 1
        while true {
            do {
                return try await sendOnce(upload, wav: wav)
            } catch let failure as RoundFailure where failure.retryable && failure.kind != .unreadable && attempt < maxAttempts {
                try await Task.sleep(for: backoff(attempt))
                attempt += 1
            }
        }
    }

    func sendOnce(_ upload: AnswerUpload, wav: Data) async throws -> VoiceRoundReceipt {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: requests.answer(upload, wav: wav)) } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RoundFailure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw RoundFailure.from(status: status, code: body?.error, message: body?.message)
        }
        do { return try JSONDecoder().decode(VoiceRoundReceipt.self, from: data) } catch { throw RoundFailure.unreadable }
    }

    /// Ends the round on the server (`RoundRequests.endRound`). Network failures and 5xx are retried with the same key.
    public func endRound(idempotencyKey: String) async throws {
        var attempt = 1
        while true {
            do {
                let data: Data, response: URLResponse
                do { (data, response) = try await session.data(for: requests.endRound(idempotencyKey: idempotencyKey)) } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw RoundFailure.offline
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
                    throw RoundFailure.from(status: status, code: body?.error, message: body?.message)
                }
                return
            } catch let failure as RoundFailure where failure.retryable && failure.kind != .unreadable && attempt < maxAttempts {
                try await Task.sleep(for: backoff(attempt))
                attempt += 1
            }
        }
    }

    /// The whole clip, for `AVAudioPlayer`. A clip that is not MP3 or WAV audio is a failure, so the watch voice speaks instead.
    public func speech(roundID: String) async throws -> SpeechClip {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: requests.speech(roundID: roundID)) } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RoundFailure.offline
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw SpeechFailure(status: status, code: body?.error)
        }
        let type = http?.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard ["audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav", "audio/wave"].contains(type), !data.isEmpty else { throw SpeechFailure(status: status, code: "not_audio") }
        return SpeechClip(data: data, contentType: type, provider: http?.value(forHTTPHeaderField: "X-Speech-Provider"))
    }
}

/// The coach voice could not be fetched; the watch voice says the question instead.
public struct SpeechFailure: Error, Sendable, Equatable {
    public let status: Int
    public let code: String?

    public init(status: Int, code: String?) { self.status = status; self.code = code }

    /// A short reason for the "Watch voice: …" line.
    public static func reason(for error: Error) -> String {
        switch error {
        case let failure as SpeechFailure where failure.code == "speech_unconfigured": "the coach has no voice set up"
        case let failure as SpeechFailure where failure.code == "not_audio": "the coach voice sent no audio"
        case let failure as SpeechFailure: "the coach voice failed (\(failure.status))"
        case let failure as RoundFailure where failure.kind == .offline: "the coach voice could not be reached"
        default: "the coach voice could not play"
        }
    }
}
