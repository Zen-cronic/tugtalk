import Foundation

/// Whether this Mac has answers in the server's open practice round, and the round end it still owes the server.
///
/// The server counts a round's answers itself (`src/voice.mjs`), across the Mac and the watch. When a round ends here
/// without a wrap-up (the bubble closed, a failed reply, another state taking the bubble, or `idleGap` of silence),
/// the Mac must say so with `POST /v1/voice-rounds/end`, or its next answer is counted as the old round's next one.
/// The same key is kept until the server confirms it, so a resend replays the first end instead of moving it.
public struct RoundEnd: Sendable, Equatable {
    /// After this long without a reply the Mac's own tally starts a new round (`RoundTally.idleGap`); the server is told too.
    public static let idleGap: TimeInterval = RoundTally.idleGap

    /// A reply arrived that did not end the round, so the server holds an open round with this Mac's answers.
    public private(set) var open = false
    /// The key of an end not yet confirmed by the server.
    public private(set) var pendingKey: String?
    /// The round id of this Mac's last answer in the round the pending end closes, sent as `X-After-Round`: if another
    /// device has answered since, the server leaves the round open (the watch may still be playing it).
    public private(set) var pendingAfterRound: String?
    private var lastReplyAt: Date?
    private var lastRoundID: String?

    public init() {}

    /// A reply arrived. A wrap-up ends the round on the server by itself.
    public mutating func replied(endsRound: Bool, at now: Date, roundID: String? = nil) {
        open = !endsRound
        lastReplyAt = endsRound ? nil : now
        lastRoundID = endsRound ? nil : roundID
    }

    /// The round ended on this Mac without a wrap-up. Returns the key to send, or nil when the server has nothing open.
    public mutating func ended(newKey: () -> String) -> String? {
        guard open || pendingKey != nil else { return nil }
        if pendingKey == nil { pendingKey = newKey(); pendingAfterRound = lastRoundID }
        open = false; lastReplyAt = nil; lastRoundID = nil
        return pendingKey
    }

    /// A hold is starting. Returns the end to send first: one still unconfirmed, or a new one when the last reply is
    /// older than `idleGap` (the Mac's tally starts that answer as a new round). Nil when nothing is owed.
    public mutating func beforeAnswer(at now: Date, newKey: () -> String) -> String? {
        if open, let lastReplyAt, now.timeIntervalSince(lastReplyAt) > Self.idleGap { return ended(newKey: newKey) }
        return pendingKey
    }

    /// The server saved (or replayed) the end sent with this key.
    public mutating func sent(_ key: String) { if pendingKey == key { pendingKey = nil; pendingAfterRound = nil } }
}

/// The receipt of `POST /v1/voice-rounds/end`. Only what the Mac checks.
public struct RoundEndReceipt: Decodable, Sendable, Equatable {
    public let receipt_id: String
    public let replayed: Bool

    public init(receipt_id: String, replayed: Bool) { self.receipt_id = receipt_id; self.replayed = replayed }
}

extension CoachAPI {
    /// `POST /v1/voice-rounds/end`: this Mac ended its practice round without a wrap-up, so the next answer from any
    /// device is answer 1. No model call. Network failures and 5xx are retried with the same key; a 4xx is returned.
    /// `afterRound`: this Mac's last answer in the round (`X-After-Round`). The server skips the end when another device
    /// has answered since; an older server ignores the header and ends the round as before.
    public func endVoiceRound(idempotencyKey: String, afterRound: String? = nil, maxAttempts: Int = 3,
                              backoff: @Sendable (Int) -> Duration = { .milliseconds(400 * $0) }) async throws -> RoundEndReceipt {
        var attempt = 1
        while true {
            var request = request("v1/voice-rounds/end", method: "POST", timeout: 15)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            if let afterRound { request.setValue(afterRound, forHTTPHeaderField: "X-After-Round") }
            request.httpBody = Data("{}".utf8)
            do {
                return try await send(request, as: RoundEndReceipt.self)
            } catch let error as CoachError where error.isRetryable && attempt < max(1, maxAttempts) {
                try await Task.sleep(for: backoff(attempt))
                attempt += 1
            }
        }
    }
}
