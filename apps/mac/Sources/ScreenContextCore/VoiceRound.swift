import Foundation

/// The language the coach transcribes and replies in.
public enum VoiceLanguage: String, CaseIterable, Sendable {
    case en, fr

    public var title: String { self == .en ? "English" : "Français" }
}

/// One hold, as sent to `POST /v1/voice-rounds`. The same `idempotencyKey` is reused on every retry.
public struct VoiceRoundRequest: Sendable, Equatable {
    public var wav: Data
    public var idempotencyKey: String
    public var goalID: String?
    public var screenContextID: String?
    public var language: VoiceLanguage
    /// When the companion finished speaking its previous question, if it finished. Used for the approximate onset.
    public var promptEndedAt: Date?
    /// When the recording started (key down). With `promptEndedAt` it gives the approximate onset.
    /// Part of the request's fingerprint, so a retry must send the same value.
    public var occurredAt: Date?

    public init(wav: Data, idempotencyKey: String, goalID: String? = nil, screenContextID: String? = nil, language: VoiceLanguage = .en,
                promptEndedAt: Date? = nil, occurredAt: Date? = nil) {
        self.wav = wav; self.idempotencyKey = idempotencyKey; self.goalID = goalID
        self.screenContextID = screenContextID; self.language = language; self.promptEndedAt = promptEndedAt; self.occurredAt = occurredAt
    }

    /// ISO 8601 with milliseconds, in UTC.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// Response shapes. Every field the card does not need is optional, so a newer server stays compatible.

public struct VoiceMetrics: Decodable, Sendable, Equatable {
    public let word_count: Int?
    public let words_per_minute: Double?
    public let filler_count: Int?
    public let hedge_count: Int?
    public let restart_count: Int?
    public let onset_ms_approx: Double?
}

public struct VoiceReply: Decodable, Sendable, Equatable {
    public enum Move: String, Sendable { case follow_up, challenge, wrap_up }

    public let move: String
    public let question: String
    public let quote: String?
    public let quote_verified: Bool?

    public var kind: Move? { Move(rawValue: move) }
    /// The quote, only when the coach checked it against the transcript.
    public var verifiedQuote: String? {
        guard quote_verified == true, let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { return nil }
        return quote
    }
}

public struct VoiceLatency: Decodable, Sendable, Equatable {
    public let asr: Double?
    public let model: Double?
    public let total: Double?

    public init(asr: Double?, model: Double?, total: Double?) { self.asr = asr; self.model = model; self.total = total }
}

public struct VoiceRoundReceipt: Decodable, Sendable, Equatable {
    public let round_id: String
    public let receipt_id: String
    public let replayed: Bool
    public let transcript: String
    public let metrics: VoiceMetrics?
    public let reply: VoiceReply
    public let model: String
    public let provider_request_id: String?
    public let latency_ms: VoiceLatency?
}

extension CoachAPI {
    /// One hold. Keep `idempotencyKey` for retries: a retry returns the original round and never pays twice.
    public func postVoiceRound(_ round: VoiceRoundRequest) async throws -> VoiceRoundReceipt {
        var request = request("v1/voice-rounds", method: "POST", timeout: 60)
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(round.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(round.language.rawValue, forHTTPHeaderField: "X-Language")
        if let goal = round.goalID { request.setValue(goal, forHTTPHeaderField: "X-Goal-Id") }
        if let card = round.screenContextID { request.setValue(card, forHTTPHeaderField: "X-Screen-Context-Id") }
        if let ended = round.promptEndedAt { request.setValue(VoiceRoundRequest.timestamp(ended), forHTTPHeaderField: "X-Prompt-Ended-At") }
        if let started = round.occurredAt { request.setValue(VoiceRoundRequest.timestamp(started), forHTTPHeaderField: "X-Occurred-At") }
        request.httpBody = round.wav
        return try await send(request, as: VoiceRoundReceipt.self)
    }
}

/// Sends a hold, retrying network failures and 5xx with the same idempotency key (except a 503
/// saying voice replies are not set up, which no retry fixes).
/// A 4xx (bad audio, key refused, too long, hourly limit) is returned at once: retrying cannot fix it.
public struct VoiceRoundUploader: Sendable {
    public let api: CoachAPI
    public let maxAttempts: Int
    public let backoff: @Sendable (Int) -> Duration

    public init(api: CoachAPI, maxAttempts: Int = 3, backoff: @escaping @Sendable (Int) -> Duration = { .milliseconds(600 * $0) }) {
        self.api = api; self.maxAttempts = max(1, maxAttempts); self.backoff = backoff
    }

    public static func isRetryable(_ error: CoachError) -> Bool {
        if case .server(503, "reply_unconfigured", _) = error { return false }
        return error.isRetryable
    }

    public func send(_ round: VoiceRoundRequest, onAttempt: @Sendable (Int) -> Void = { _ in }) async throws -> VoiceRoundReceipt {
        var attempt = 1
        while true {
            onAttempt(attempt)
            do {
                return try await api.postVoiceRound(round)
            } catch let error as CoachError where Self.isRetryable(error) && attempt < maxAttempts {
                try await Task.sleep(for: backoff(attempt))
                attempt += 1
            }
        }
    }
}
