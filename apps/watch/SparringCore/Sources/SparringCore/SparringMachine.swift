import Foundation

/// One spoken practice round on the watch, as a pure state machine. Tap Record, answer, tap Stop; the coach's
/// question comes back and is spoken; answer again. The round ends when the server's move gate allows only
/// `wrap_up` (code measured a close, or the fourth answer), as on the Mac. `maxAnswers` is the same cap, kept here
/// too so a server without the gate still ends the round. It decides; the app performs the effects (microphone,
/// upload, speech), so every transition is unit-tested without a watch.
public struct SparringMachine: Sendable {
    /// The server's `ANSWER_CAP` (src/counterpart.mjs).
    public static let maxAnswers = 4
    /// The server refuses audio under 0.5 s; a shorter recording is a stray tap and is never sent.
    public static let minimumAnswer: TimeInterval = 0.5
    /// After this long, the last question no longer marks the start of an answer (the Mac uses the same).
    public static let promptExpiry: TimeInterval = 300

    /// A question on screen.
    public struct Shown: Sendable, Equatable {
        public let answer: Int
        public let roundID: String
        public let question: String
        public let quote: String?
        public let transcript: String
        public let mediaNote: String?
        public let endsRound: Bool
        /// The gate's reason when it ended the round: `measured_close` or `answer_cap`.
        public let closedBy: String?
        /// Nil while the voice is being fetched.
        public var voice: SpeechVoice?
        /// The question has been spoken (or could not be): the screen says "Your turn".
        public var spoken: Bool
    }

    public enum Phase: Sendable, Equatable {
        /// Waiting for Record. `answer` is the answer the next recording will be.
        case ready(answer: Int)
        case recording(answer: Int, upload: AnswerUpload)
        case thinking(answer: Int, upload: AnswerUpload)
        case replying(Shown)
        /// `upload` is kept only when Retry can resend it.
        case failed(answer: Int, failure: RoundFailure, upload: AnswerUpload?)
        case done(RoundSummary?, lastQuestion: String?, mediaNote: String?, closedBy: String?)

        public var name: String {
            switch self {
            case .ready: "ready"
            case .recording: "recording"
            case .thinking: "thinking"
            case .replying(let shown): shown.spoken ? "your turn" : "speaking"
            case .failed(_, let failure, let upload): "failed \(failure.kind.rawValue)\(upload == nil ? "" : " (retry)")"
            case .done: "done"
            }
        }
    }

    public enum Effect: Sendable, Equatable {
        case startRecording(key: String)
        /// Stop the microphone and keep the file under this key.
        case stopRecording(key: String)
        case upload(AnswerUpload)
        /// The recording under this key is no longer needed.
        case discard(key: String)
        /// English: fetch the coach voice for this round.
        case fetchSpeech(roundID: String)
        /// The watch voice says this, in this language.
        case speakOnDevice(String, VoiceLanguage)
        case stopSpeech
        /// Tell the server this round ended without a wrap-up (`POST /v1/voice-rounds/end`), so the next answer from any
        /// device is answer 1. Resent with the same key until `roundEndSent(key:)`.
        case endRoundOnServer(key: String)
    }

    public let goalID: String?
    public let language: VoiceLanguage
    /// The Mac's screen card this round is about (`ScreenCard.pick`), sent with every answer. Dropped if the server no
    /// longer has it (404), so the round goes on without it.
    public private(set) var screenContextID: String?
    public private(set) var phase: Phase = .ready(answer: 1)
    /// The server's measurements of each answer so far.
    public private(set) var metrics: [VoiceMetrics] = []
    private var promptEndedAt: Date?
    /// The other person's need for this round, from the first reply that named one. Never stored on the watch beyond the round.
    public private(set) var need: String?
    /// The server holds this round open: it replied to an answer, and not with a wrap-up. The server counts the round's
    /// answers itself, so a round that ends here any other way must be ended there too.
    private var serverOpen = false
    /// The key of a round end the server has not confirmed yet.
    public private(set) var pendingEndKey: String?
    private let newKey: @Sendable () -> String
    private let newEndKey: @Sendable () -> String

    /// `pendingEndKey`: a round end an earlier screen sent but the server never confirmed (`PendingRoundEndStore`). It is
    /// sent again, with the same key, before this screen's first answer.
    public init(goalID: String?, language: VoiceLanguage, screenContextID: String? = nil, pendingEndKey: String? = nil,
                newKey: @escaping @Sendable () -> String = { RoundRequests.newIdempotencyKey() },
                newEndKey: @escaping @Sendable () -> String = { RoundRequests.newRoundEndKey() }) {
        self.goalID = goalID; self.language = language; self.screenContextID = screenContextID; self.pendingEndKey = pendingEndKey
        self.newKey = newKey; self.newEndKey = newEndKey
    }

    /// Answers the server has replied to.
    public var answered: Int { metrics.count }

    /// Record tapped: on "Your turn", on a question still being spoken (it stops), on a failure, or on
    /// Round done ("Record again" starts a new round).
    public mutating func record(at now: Date) -> [Effect] {
        switch phase {
        case .ready(let answer):
            return start(answer, at: now, prompt: currentPrompt(at: now))
        case .replying(let shown):
            guard !shown.endsRound else { return [] }
            // Cut off mid-question, it has no end to measure an onset from.
            let prompt = shown.spoken ? currentPrompt(at: now) : nil
            return (shown.spoken ? [] : [.stopSpeech]) + start(shown.answer + 1, at: now, prompt: prompt)
        case .failed(let answer, _, let upload):
            let drop: [Effect] = upload.map { [.discard(key: $0.idempotencyKey)] } ?? []
            return drop + start(answer, at: now, prompt: currentPrompt(at: now))
        case .done:
            metrics = []; promptEndedAt = nil; need = nil
            return start(1, at: now, prompt: nil)
        case .recording, .thinking:
            return []
        }
    }

    /// Stop tapped, or the recorder reached its cap (`capped`).
    public mutating func stop(at now: Date, capped: Bool = false) -> [Effect] {
        guard case .recording(let answer, let upload) = phase else { return [] }
        if !capped && now.timeIntervalSince(upload.occurredAt) < Self.minimumAnswer {
            // A stray tap does not use up the question's end time.
            promptEndedAt = upload.promptEndedAt
            phase = .failed(answer: answer, failure: .tooShort, upload: nil)
            return [.stopRecording(key: upload.idempotencyKey), .discard(key: upload.idempotencyKey)]
        }
        phase = .thinking(answer: answer, upload: upload)
        return [.stopRecording(key: upload.idempotencyKey), .upload(upload)]
    }

    /// Record was tapped but cannot start (microphone permission is off): the screen says why, and Try again
    /// asks again. A question still being spoken stops.
    public mutating func refuse(_ failure: RoundFailure) -> [Effect] {
        let next: Int, effects: [Effect]
        switch phase {
        case .ready(let answer): next = answer; effects = []
        case .replying(let shown) where !shown.endsRound: next = shown.answer + 1; effects = shown.spoken ? [] : [.stopSpeech]
        case .failed(let answer, _, let upload): next = answer; effects = upload.map { [.discard(key: $0.idempotencyKey)] } ?? []
        case .done: metrics = []; need = nil; next = 1; effects = []
        default: return []
        }
        promptEndedAt = nil
        phase = .failed(answer: next, failure: failure, upload: nil)
        return effects
    }

    /// The microphone could not open, or permission is off.
    public mutating func recordingFailed(_ failure: RoundFailure) -> [Effect] {
        guard case .recording(let answer, let upload) = phase else { return [] }
        phase = .failed(answer: answer, failure: failure, upload: nil)
        return [.discard(key: upload.idempotencyKey)]
    }

    /// The server replied. Ignored unless it is for the answer being waited on.
    public mutating func replied(key: String, _ receipt: VoiceRoundReceipt) -> [Effect] {
        guard case .thinking(let answer, let upload) = phase, upload.idempotencyKey == key else { return [] }
        let question = receipt.reply.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            phase = .failed(answer: answer, failure: .noQuestion, upload: nil)
            return [.discard(key: key)]
        }
        if let m = receipt.metrics { metrics.append(m) }
        serverOpen = !receipt.reply.wrapsUp
        if need == nil, let named = receipt.counterpart?.need { need = named }
        let ends = receipt.reply.wrapsUp || answer >= Self.maxAnswers
        let reason = receipt.counterpart?.reason.flatMap { $0 == "open" ? nil : $0 } ?? (receipt.reply.wrapsUp ? nil : (ends ? "answer_cap" : nil))
        let shown = Shown(answer: answer, roundID: receipt.round_id, question: question, quote: receipt.reply.verifiedQuote,
                          transcript: receipt.transcript, mediaNote: receipt.media?.note,
                          endsRound: ends, closedBy: ends ? reason : nil, voice: nil, spoken: false)
        // French has no coach voice (Wit.ai is English only): the watch voice speaks it without asking.
        if language == .fr {
            var spoken = shown
            spoken.voice = .watch(reason: "no coach voice in French")
            phase = .replying(spoken)
            return [.discard(key: key), .speakOnDevice(question, .fr)]
        }
        phase = .replying(shown)
        return [.discard(key: key), .fetchSpeech(roundID: receipt.round_id)]
    }

    public mutating func uploadFailed(key: String, _ failure: RoundFailure) -> [Effect] {
        guard case .thinking(let answer, let upload) = phase, upload.idempotencyKey == key else { return [] }
        // The screen card was hidden on the Mac after the overview was read: the same answer goes again without it.
        // Nothing was saved under this key (the server refused before any model call), so the key is reused. Only the
        // server's `screen_context_not_found` means that; another 404 (a deleted goal) is an ordinary failure.
        if failure.screenCardGone, upload.screenContextID != nil {
            screenContextID = nil
            let again = upload.withoutScreenCard()
            phase = .thinking(answer: answer, upload: again)
            return [.upload(again)]
        }
        if failure.retryable {
            phase = .failed(answer: answer, failure: failure, upload: upload)
            return []
        }
        phase = .failed(answer: answer, failure: failure, upload: nil)
        return [.discard(key: key)]
    }

    /// Retry: the same recording, the same key and the same headers, so the server never runs (or bills) it twice.
    public mutating func retry() -> [Effect] {
        guard case .failed(let answer, _, let upload?) = phase else { return [] }
        phase = .thinking(answer: answer, upload: upload)
        return [.upload(upload)]
    }

    /// The coach voice started playing.
    public mutating func speechStarted(roundID: String, provider: String?) -> [Effect] {
        guard case .replying(var shown) = phase, shown.roundID == roundID, !shown.spoken else { return [] }
        shown.voice = .coach(provider: provider)
        phase = .replying(shown)
        return []
    }

    /// The coach voice failed before playing: the question stays on screen and the watch voice says it.
    public mutating func speechFailed(roundID: String, reason: String) -> [Effect] {
        guard case .replying(var shown) = phase, shown.roundID == roundID, !shown.spoken, shown.voice == nil else { return [] }
        shown.voice = .watch(reason: reason)
        phase = .replying(shown)
        return [.speakOnDevice(shown.question, language)]
    }

    /// The question finished playing (or neither voice could play it). Its end time goes with the next answer.
    public mutating func speechFinished(roundID: String, at now: Date) -> [Effect] {
        guard case .replying(var shown) = phase, shown.roundID == roundID, !shown.spoken else { return [] }
        if shown.voice == nil { shown.voice = .watch(reason: "no voice could play") }
        shown.spoken = true
        if shown.endsRound { return finish() }
        promptEndedAt = now
        phase = .replying(shown)
        return []
    }

    /// "See result" on the last question, before it has finished playing.
    public mutating func skipToResult() -> [Effect] {
        guard case .replying(let shown) = phase, shown.endsRound else { return [] }
        return [.stopSpeech] + finish()
    }

    /// "End round": the summary of the answers so far. With none, back to the first answer.
    public mutating func endRound() -> [Effect] {
        var effects: [Effect] = []
        switch phase {
        case .recording(_, let upload): effects = [.stopRecording(key: upload.idempotencyKey), .discard(key: upload.idempotencyKey)]
        case .failed(_, _, let upload?): effects = [.discard(key: upload.idempotencyKey)]
        case .replying(let shown) where !shown.spoken: effects = [.stopSpeech]
        case .thinking, .done: return []
        default: break
        }
        if metrics.isEmpty {
            phase = .ready(answer: 1); promptEndedAt = nil; need = nil
            return effects + owedEnd()
        }
        return effects + finish()
    }

    /// The screen closed. A round the server still holds open is ended there, so the next round starts at answer 1.
    /// An answer still uploading is saved by the server anyway and holds its round open, so it is owed an end too
    /// (the app sends it after the upload finishes), and its late reply is ignored.
    public mutating func leave() -> [Effect] {
        if case .thinking = phase { serverOpen = true; phase = .ready(answer: 1) }
        return owedEnd()
    }

    /// The server saved (or replayed) the round end sent with this key.
    public mutating func roundEndSent(key: String) { if pendingEndKey == key { pendingEndKey = nil } }

    private mutating func finish() -> [Effect] {
        var lastQuestion: String?, note: String?, closedBy: String?
        if case .replying(let shown) = phase { lastQuestion = shown.question; note = shown.mediaNote; closedBy = shown.closedBy }
        phase = .done(RoundSummary.make(metrics), lastQuestion: lastQuestion, mediaNote: note, closedBy: closedBy)
        promptEndedAt = nil; need = nil
        // A wrap-up ended the round on the server already; End round, or the watch's own fourth-answer stop, did not.
        return owedEnd()
    }

    /// The round end the server is owed: a new one when it holds this round open, or the one not yet confirmed.
    private mutating func owedEnd() -> [Effect] {
        if serverOpen { serverOpen = false; pendingEndKey = pendingEndKey ?? newEndKey() }
        return pendingEndKey.map { [.endRoundOnServer(key: $0)] } ?? []
    }

    private func currentPrompt(at now: Date) -> Date? {
        guard let ended = promptEndedAt, now.timeIntervalSince(ended) <= Self.promptExpiry else { return nil }
        return ended
    }

    private mutating func start(_ answer: Int, at now: Date, prompt: Date?) -> [Effect] {
        let upload = AnswerUpload(idempotencyKey: newKey(), goalID: goalID, language: language, occurredAt: now, promptEndedAt: prompt, need: need,
                                  screenContextID: screenContextID)
        promptEndedAt = nil
        phase = .recording(answer: answer, upload: upload)
        // A round end still unconfirmed is sent again (same key) before the first answer of the next round.
        let resend: [Effect] = answer == 1 ? pendingEndKey.map { [.endRoundOnServer(key: $0)] } ?? [] : []
        return resend + [.startRecording(key: upload.idempotencyKey)]
    }
}
