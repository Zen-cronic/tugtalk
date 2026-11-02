import Foundation

/// The hold-to-talk loop as a pure state machine: key down, key up, reply, speech finished.
/// It decides; the app performs the effects (microphone, upload, speech). Kept free of AVFoundation
/// so every transition, barge-in included, is unit-tested.
public struct VoiceTurnMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The microphone is open. `promptEndedAt` is what this hold will send as `X-Prompt-Ended-At`.
        case listening(key: String, since: Date, promptEndedAt: Date?)
        case thinking(key: String, since: Date, promptEndedAt: Date?)
        case speaking(key: String, question: String, endsRound: Bool)
        case failed(key: String, retryable: Bool, promptEndedAt: Date?)
    }

    public enum Effect: Equatable, Sendable {
        case stopSpeaking
        case startRecording(key: String)
        /// Stop the microphone, keep the clip, and send it.
        case upload(key: String, promptEndedAt: Date?)
        case discard(key: String)
        case speak(String)
        /// A tap too short to be an answer: nothing is sent.
        case tooShort
    }

    /// Shorter than this is a tap, not an answer.
    public static let minimumHold: TimeInterval = 0.35
    /// After this long, the last question no longer marks the start of an answer.
    public static let promptExpiry: TimeInterval = 300

    public private(set) var phase: Phase = .idle
    /// When the last question finished playing in full. Cleared by barge-in, a dismissed reply or the end of a round.
    public private(set) var promptEndedAt: Date?
    private let newKey: @Sendable () -> String

    public init(newKey: @escaping @Sendable () -> String = { CoachAPI.newIdempotencyKey(prefix: "voice") }) {
        self.newKey = newKey
    }

    /// ⌃⌥T pressed. Starts a hold; while the companion is speaking, stops it first (barge-in).
    public mutating func keyDown(at now: Date) -> [Effect] {
        switch phase {
        case .idle:
            return startHold(at: now, prompt: currentPrompt(at: now))
        case .failed(let old, _, _):
            return [.discard(key: old)] + startHold(at: now, prompt: currentPrompt(at: now))
        case .speaking:
            // The question was cut off, so it has no end to measure an onset from.
            promptEndedAt = nil
            return [.stopSpeaking] + startHold(at: now, prompt: nil)
        case .listening, .thinking:
            // Key repeat while held, or a press while a reply is on its way: one round at a time.
            return []
        }
    }

    /// ⌃⌥T released, or the 60 s cap reached (`capped`).
    public mutating func keyUp(at now: Date, capped: Bool = false) -> [Effect] {
        guard case .listening(let key, let since, let prompt) = phase else { return [] }
        if !capped && now.timeIntervalSince(since) < Self.minimumHold {
            // A stray tap does not use up the question's end time.
            phase = .idle
            promptEndedAt = prompt
            return [.discard(key: key), .tooShort]
        }
        phase = .thinking(key: key, since: now, promptEndedAt: prompt)
        return [.upload(key: key, promptEndedAt: prompt)]
    }

    /// The whole reply arrived. Ignored if it belongs to an older hold.
    public mutating func replyReady(key: String, question: String, endsRound: Bool) -> [Effect] {
        guard case .thinking(key, _, _) = phase else { return [] }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .failed(key: key, retryable: false, promptEndedAt: nil)
            return [.discard(key: key)]
        }
        phase = .speaking(key: key, question: text, endsRound: endsRound)
        return [.discard(key: key), .speak(text)]
    }

    public mutating func uploadFailed(key: String, retryable: Bool) -> [Effect] {
        guard case .thinking(key, _, let prompt) = phase else { return [] }
        phase = .failed(key: key, retryable: retryable, promptEndedAt: prompt)
        return retryable ? [] : [.discard(key: key)]
    }

    /// Retry from the error card: the same clip and the same idempotency key.
    public mutating func retry(at now: Date) -> [Effect] {
        guard case .failed(let key, true, let prompt) = phase else { return [] }
        phase = .thinking(key: key, since: now, promptEndedAt: prompt)
        return [.upload(key: key, promptEndedAt: prompt)]
    }

    /// The question played to the end. Its end time goes with the next hold, unless the round is over.
    public mutating func speechFinished(at now: Date) -> [Effect] {
        guard case .speaking(_, _, let endsRound) = phase else { return [] }
        promptEndedAt = endsRound ? nil : now
        phase = .idle
        return []
    }

    /// The hold was abandoned without a release (the docked panel closed under the Talk button, or the app
    /// lost focus mid-hold): the microphone closes and the clip is dropped, never sent. Only a hold is
    /// affected, and like a tap it does not use up the last question's end time.
    public mutating func cancelHold() -> [Effect] {
        guard case .listening(let key, _, let prompt) = phase else { return [] }
        phase = .idle
        promptEndedAt = prompt
        return [.discard(key: key)]
    }

    /// The reply or the error card was closed.
    public mutating func dismiss() -> [Effect] {
        switch phase {
        case .speaking:
            promptEndedAt = nil
            phase = .idle
            return [.stopSpeaking]
        case .failed(let key, _, _):
            phase = .idle
            return [.discard(key: key)]
        case .listening(let key, _, _):
            phase = .idle
            return [.discard(key: key)]
        case .idle, .thinking:
            return []
        }
    }

    private func currentPrompt(at now: Date) -> Date? {
        guard let ended = promptEndedAt, now.timeIntervalSince(ended) <= Self.promptExpiry else { return nil }
        return ended
    }

    private mutating func startHold(at now: Date, prompt: Date?) -> [Effect] {
        let key = newKey()
        promptEndedAt = nil
        phase = .listening(key: key, since: now, promptEndedAt: prompt)
        return [.startRecording(key: key)]
    }
}
