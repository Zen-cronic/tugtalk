import Foundation

// The voice-round contract (docs/voice.md), as the watch uses it. These mirror the Mac's types in
// apps/mac/Sources/ScreenContextCore/VoiceRound.swift; that package is macOS-only (it links ScreenCaptureKit
// and Vision), so the few small types the watch needs are kept here instead.

/// The language the coach transcribes and replies in.
public enum VoiceLanguage: String, CaseIterable, Sendable {
    case en, fr
}

/// One answer, as sent to `POST /v1/voice-rounds`. Every field is fixed when the recording stops, so a retry
/// is byte for byte the same request and the server replays the saved round instead of running it again.
public struct AnswerUpload: Sendable, Equatable {
    public let idempotencyKey: String
    public let goalID: String?
    public let language: VoiceLanguage
    /// When the recording started; sent as `X-Occurred-At`.
    public let occurredAt: Date
    /// When the previous question finished playing in full, if it did; sent as `X-Prompt-Ended-At`.
    public let promptEndedAt: Date?
    /// What the other person needs in this practice round, as the round's first reply named it; sent back as
    /// `X-Counterpart-Need` so code can measure each answer against it. Part of the retry fingerprint when sent.
    public let need: String?

    public init(idempotencyKey: String, goalID: String?, language: VoiceLanguage, occurredAt: Date, promptEndedAt: Date?, need: String? = nil) {
        self.idempotencyKey = idempotencyKey; self.goalID = goalID; self.language = language
        self.occurredAt = occurredAt; self.promptEndedAt = promptEndedAt; self.need = need
    }

    /// ISO 8601 with milliseconds, in UTC.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// Response shapes. Fields the watch does not show are left out; Decodable ignores them.

public struct VoiceMetrics: Decodable, Sendable, Equatable {
    public let word_count: Int?
    public let words_per_minute: Double?
    public let filler_count: Int?
    public let hedge_count: Int?
    public let restart_count: Int?

    public init(word_count: Int? = nil, words_per_minute: Double? = nil, filler_count: Int?, hedge_count: Int?, restart_count: Int?) {
        self.word_count = word_count; self.words_per_minute = words_per_minute
        self.filler_count = filler_count; self.hedge_count = hedge_count; self.restart_count = restart_count
    }
}

public struct VoiceReply: Decodable, Sendable, Equatable {
    public let move: String
    public let question: String
    public let quote: String?
    public let quote_verified: Bool?

    public init(move: String, question: String, quote: String?, quote_verified: Bool?) {
        self.move = move; self.question = question; self.quote = quote; self.quote_verified = quote_verified
    }

    public var wrapsUp: Bool { move == "wrap_up" }

    /// The quote, only when code on the server checked it against the transcript.
    public var verifiedQuote: String? {
        guard quote_verified == true, let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { return nil }
        return quote
    }
}

/// The move gate's decision for this answer (src/counterpart.mjs). Code, not the model, decides when the round ends.
public struct Counterpart: Decodable, Sendable, Equatable {
    public let need: String?
    public let need_met: Bool?
    public let allowed: [String]?
    /// `open`, `measured_close` or `answer_cap`.
    public let reason: String?
    public let answer: Int?

    public init(need: String? = nil, need_met: Bool? = nil, allowed: [String]? = nil, reason: String? = nil, answer: Int? = nil) {
        self.need = need; self.need_met = need_met; self.allowed = allowed; self.reason = reason; self.answer = answer
    }
}

/// The `media` block: present only when Keep my recordings is on.
public struct RoundMedia: Decodable, Sendable, Equatable {
    public let kept: Bool
    public let reason: String?

    public init(kept: Bool, reason: String?) { self.kept = kept; self.reason = reason }

    /// The line the screen shows, or nil.
    public var note: String? { kept ? "Recording kept" : (reason == "full" ? "Recording not kept: storage full" : nil) }
}

public struct VoiceRoundReceipt: Decodable, Sendable, Equatable {
    public let round_id: String
    public let receipt_id: String
    public let replayed: Bool
    public let transcript: String
    public let metrics: VoiceMetrics?
    public let reply: VoiceReply
    public let media: RoundMedia?
    /// Absent on a replayed receipt and on servers before contract 0.7.
    public let counterpart: Counterpart?

    public init(round_id: String, receipt_id: String, replayed: Bool, transcript: String, metrics: VoiceMetrics?, reply: VoiceReply,
                media: RoundMedia? = nil, counterpart: Counterpart? = nil) {
        self.round_id = round_id; self.receipt_id = receipt_id; self.replayed = replayed; self.transcript = transcript
        self.metrics = metrics; self.reply = reply; self.media = media; self.counterpart = counterpart
    }
}

/// Builds the two requests a turn makes. Pure, so the headers are unit-tested.
public struct RoundRequests: Sendable {
    public let baseURL: URL
    private let token: String

    public init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }

    /// `POST /v1/voice-rounds` with the WAV as the body. The headers are the round's parameters (src/voice.mjs `voiceParams`).
    public func answer(_ upload: AnswerUpload, wav: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v1/voice-rounds"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(upload.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(upload.language.rawValue, forHTTPHeaderField: "X-Language")
        if let goal = upload.goalID { request.setValue(goal, forHTTPHeaderField: "X-Goal-Id") }
        request.setValue(AnswerUpload.timestamp(upload.occurredAt), forHTTPHeaderField: "X-Occurred-At")
        if let ended = upload.promptEndedAt { request.setValue(AnswerUpload.timestamp(ended), forHTTPHeaderField: "X-Prompt-Ended-At") }
        if let need = upload.need { request.setValue(need, forHTTPHeaderField: "X-Counterpart-Need") }
        request.httpBody = wav
        return request
    }

    /// `POST /v1/voice-rounds/{round_id}/speech`: the round's checked question as audio (MP3 from Wit.ai).
    public func speech(roundID: String) -> URLRequest {
        let id = roundID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? roundID
        var request = URLRequest(url: baseURL.appending(path: "v1/voice-rounds/\(id)/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mpeg, audio/wav", forHTTPHeaderField: "Accept")
        return request
    }

    public static func newIdempotencyKey() -> String { "watch-voice-\(UUID().uuidString.lowercased())" }
}
