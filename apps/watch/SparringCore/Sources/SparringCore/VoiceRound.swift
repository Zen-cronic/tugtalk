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
    /// The Mac's latest screen card for this goal (`ScreenCard.pick`), sent as `X-Screen-Context-Id`. With it, the
    /// round's first reply picks the other person's need from the card, as on the Mac.
    public let screenContextID: String?

    public init(idempotencyKey: String, goalID: String?, language: VoiceLanguage, occurredAt: Date, promptEndedAt: Date?, need: String? = nil,
                screenContextID: String? = nil) {
        self.idempotencyKey = idempotencyKey; self.goalID = goalID; self.language = language
        self.occurredAt = occurredAt; self.promptEndedAt = promptEndedAt; self.need = need; self.screenContextID = screenContextID
    }

    /// The same answer without the screen card (the card was hidden after the overview was read).
    public func withoutScreenCard() -> AnswerUpload {
        AnswerUpload(idempotencyKey: idempotencyKey, goalID: goalID, language: language, occurredAt: occurredAt, promptEndedAt: promptEndedAt, need: need)
    }

    /// ISO 8601 with milliseconds, in UTC.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// A screen card as the overview lists it (`latest_screen_context`, per goal and for the account): only what the watch
/// needs to pick one. The card itself (a model-written summary of one Mac window) stays on the server.
public struct ScreenCard: Decodable, Sendable, Hashable {
    public let id: String
    public let occurred_at: String
    public let goal_id: String?

    public init(id: String, occurred_at: String, goal_id: String?) { self.id = id; self.occurred_at = occurred_at; self.goal_id = goal_id }

    /// A card older than this is not about the conversation being practised now.
    public static let maxAge: TimeInterval = 60 * 60

    /// The card a watch round is about: the selected goal's latest card, or else the account's latest card when no goal
    /// owns it (with no goal selected, the account's latest card, as the Mac sends its last card); only when it is less
    /// than `maxAge` old. Never a card that belongs to another goal. Nil: no card is sent, and the round runs as
    /// before, without a need.
    public static func pick(goalCard: ScreenCard?, latest: ScreenCard?, goalID: String?, now: Date) -> String? {
        let candidates = [goalID == nil ? nil : goalCard, latest.flatMap { goalID == nil || $0.goal_id == nil || $0.goal_id == goalID ? $0 : nil }]
        return candidates.compactMap { $0 }.first { card in
            guard let at = parse(card.occurred_at) else { return false }
            return now.timeIntervalSince(at) <= maxAge && at.timeIntervalSince(now) < 60
        }?.id
    }

    private static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
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
        if let card = upload.screenContextID { request.setValue(card, forHTTPHeaderField: "X-Screen-Context-Id") }
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

    /// `POST /v1/voice-rounds/end` with the body `{}`: this round ended on the watch without a wrap-up (End round), so
    /// the next answer from any device is answer 1. No model call; a retry with the same key replays the first end.
    public func endRound(idempotencyKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v1/voice-rounds/end"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = Data("{}".utf8)
        return request
    }

    public static func newIdempotencyKey() -> String { "watch-voice-\(UUID().uuidString.lowercased())" }
    public static func newRoundEndKey() -> String { "watch-round-end-\(UUID().uuidString.lowercased())" }
}
