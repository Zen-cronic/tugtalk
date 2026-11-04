import Foundation
import Testing
@testable import SparringCore

private final class Keys: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> String { lock.withLock { n += 1; return "key-\(n)" } }
}

private func receipt(_ id: String, move: String = "challenge", question: String = "Why should it be you?", quote: String? = "maybe lead",
                     verified: Bool = true, fillers: Int = 1, hedges: Int = 0, restarts: Int = 0, kept: Bool? = nil,
                     counterpart: Counterpart? = nil) -> VoiceRoundReceipt {
    VoiceRoundReceipt(round_id: id, receipt_id: "r-\(id)", replayed: false, transcript: "So um I could maybe lead the launch.",
                      metrics: VoiceMetrics(filler_count: fillers, hedge_count: hedges, restart_count: restarts),
                      reply: VoiceReply(move: move, question: question, quote: quote, quote_verified: verified),
                      media: kept.map { RoundMedia(kept: $0, reason: nil) }, counterpart: counterpart)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Records, stops after `seconds`, and returns the upload the stop produced.
private func answer(_ m: inout SparringMachine, at start: Date, seconds: TimeInterval = 3) -> AnswerUpload {
    _ = m.record(at: start)
    let effects = m.stop(at: start.addingTimeInterval(seconds))
    for case .upload(let upload) in effects { return upload }
    Issue.record("no upload after stop: \(effects)")
    return AnswerUpload(idempotencyKey: "", goalID: nil, language: .en, occurredAt: start, promptEndedAt: nil)
}

@Suite struct TurnCount {
    @Test func aRoundEndsAtTheFourthAnswerWithoutAWrapUp() {
        let keys = Keys()
        var m = SparringMachine(goalID: "g1", language: .en, newKey: keys.next)
        #expect(m.phase == .ready(answer: 1))
        var at = t0
        for n in 1...4 {
            if n == 1 { #expect(m.phase == .ready(answer: 1)) }
            let up = answer(&m, at: at)
            guard case .thinking(let a, _) = m.phase else { Issue.record("not thinking: \(m.phase.name)"); return }
            #expect(a == n)
            #expect(m.replied(key: up.idempotencyKey, receipt("round-\(n)", fillers: 5 - n)) == [.discard(key: up.idempotencyKey), .fetchSpeech(roundID: "round-\(n)")])
            guard case .replying(let shown) = m.phase else { Issue.record("not replying"); return }
            #expect(shown.answer == n)
            #expect(shown.endsRound == (n == 4))
            #expect(shown.closedBy == (n == 4 ? "answer_cap" : nil))
            at = at.addingTimeInterval(10)
            _ = m.speechStarted(roundID: "round-\(n)", provider: "wit")
            _ = m.speechFinished(roundID: "round-\(n)", at: at)
            at = at.addingTimeInterval(1)
        }
        guard case .done(let summary?, let last, _, let closedBy) = m.phase else { Issue.record("not done: \(m.phase.name)"); return }
        #expect(m.answered == 4 && closedBy == "answer_cap")
        #expect(summary.habit == .filler && summary.first == 4 && summary.last == 1 && summary.answers == 4)
        #expect(summary.comparison == "In your last answer, down from 4 in your first" && summary.unit == "filler")
        #expect(summary.source == "Counted by the server in answers 1 and 4")
        #expect(last == "Why should it be you?")
    }

    @Test func noFifthAnswerAfterTheLastQuestion() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next, newEndKey: { "end-1" })
        var at = t0
        for n in 1...4 {
            let up = answer(&m, at: at)
            _ = m.replied(key: up.idempotencyKey, receipt("r\(n)"))
            at = at.addingTimeInterval(10)
            if n < 4 { _ = m.speechFinished(roundID: "r\(n)", at: at) }
        }
        // The last question is still being spoken: Record does nothing, only See result.
        #expect(m.record(at: at) == [])
        // This server never wrapped up (no move gate), so the watch's own stop ends the round there too.
        #expect(m.skipToResult() == [.stopSpeech, .endRoundOnServer(key: "end-1")])
        guard case .done = m.phase else { Issue.record("not done"); return }
    }

    @Test func aWrapUpEndsTheRoundEarly() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up1 = answer(&m, at: t0)
        _ = m.replied(key: up1.idempotencyKey, receipt("r1", fillers: 2))
        _ = m.speechFinished(roundID: "r1", at: t0.addingTimeInterval(8))
        let up2 = answer(&m, at: t0.addingTimeInterval(9))
        _ = m.replied(key: up2.idempotencyKey, receipt("r2", move: "wrap_up", fillers: 2,
                                                        counterpart: Counterpart(allowed: ["wrap_up"], reason: "measured_close", answer: 2)))
        _ = m.speechFinished(roundID: "r2", at: t0.addingTimeInterval(20))
        guard case .done(let summary?, _, _, let closedBy) = m.phase else { Issue.record("not done"); return }
        #expect(summary.answers == 2 && closedBy == "measured_close")
        #expect(summary.comparison == "In your last answer, the same as your first")
    }

    @Test func recordAgainStartsANewRound() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1", move: "wrap_up"))
        _ = m.speechFinished(roundID: "r1", at: t0.addingTimeInterval(5))
        guard case .done(let summary?, _, _, _) = m.phase else { Issue.record("not done"); return }
        #expect(summary.first == nil && summary.comparison == "In your answer" && summary.unit == "filler")
        _ = m.record(at: t0.addingTimeInterval(9))
        guard case .recording(let a, let next) = m.phase else { Issue.record("not recording"); return }
        #expect(a == 1 && next.promptEndedAt == nil && m.answered == 0)
    }

    @Test func theNextAnswerCarriesTheQuestionsEndTime() {
        var m = SparringMachine(goalID: "g1", language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        #expect(up.promptEndedAt == nil && up.goalID == "g1")
        _ = m.replied(key: up.idempotencyKey, receipt("r1"))
        let ended = t0.addingTimeInterval(8)
        _ = m.speechFinished(roundID: "r1", at: ended)
        let up2 = answer(&m, at: ended.addingTimeInterval(2))
        #expect(up2.promptEndedAt == ended)
    }

    @Test func theNeedFromTheFirstReplyGoesWithEveryLaterAnswerAndRetry() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up1 = answer(&m, at: t0)
        #expect(up1.need == nil)
        _ = m.replied(key: up1.idempotencyKey, receipt("r1", counterpart: Counterpart(need: "date", reason: "open", answer: 1)))
        _ = m.speechFinished(roundID: "r1", at: t0.addingTimeInterval(5))
        let up2 = answer(&m, at: t0.addingTimeInterval(6))
        #expect(up2.need == "date")
        _ = m.uploadFailed(key: up2.idempotencyKey, .offline)
        #expect(m.retry() == [.upload(up2)])
        // A need offered later does not replace it.
        _ = m.replied(key: up2.idempotencyKey, receipt("r2", counterpart: Counterpart(need: "owner", reason: "open", answer: 2)))
        #expect(m.need == "date")
        _ = m.endRound()
        #expect(m.need == nil)
    }

    @Test func tappingRecordWhileSpeakingStopsTheVoiceAndSendsNoQuestionEnd() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1"))
        let effects = m.record(at: t0.addingTimeInterval(5))
        #expect(effects.first == .stopSpeech)
        guard case .recording(2, let next) = m.phase else { Issue.record("not recording answer 2"); return }
        #expect(next.promptEndedAt == nil)
    }

    @Test func aStrayTapIsNotSent() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        _ = m.record(at: t0)
        let effects = m.stop(at: t0.addingTimeInterval(0.2))
        #expect(effects == [.stopRecording(key: "key-1"), .discard(key: "key-1")])
        #expect(m.phase == .failed(answer: 1, failure: .tooShort, upload: nil))
    }

    @Test func aReplyForAnotherAnswerIsIgnored() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        _ = answer(&m, at: t0)
        #expect(m.replied(key: "someone-else", receipt("r1")) == [])
        #expect(m.phase.name == "thinking")
    }

    @Test func keptRecordingIsShown() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1", kept: true))
        guard case .replying(let shown) = m.phase else { Issue.record("not replying"); return }
        #expect(shown.mediaNote == "Recording kept")
    }

    @Test func anUnverifiedQuoteIsNotShown() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1", quote: "we will triple revenue", verified: false))
        guard case .replying(let shown) = m.phase else { Issue.record("not replying"); return }
        #expect(shown.quote == nil)
    }
}

@Suite struct Failures {
    @Test func retryReusesTheSameIdempotencyKeyAndHeaders() {
        var m = SparringMachine(goalID: "g1", language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        #expect(m.uploadFailed(key: up.idempotencyKey, .offline) == [])
        guard case .failed(1, .offline, let kept?) = m.phase else { Issue.record("no retryable failure"); return }
        #expect(kept == up)
        #expect(m.retry() == [.upload(up)])
        #expect(m.phase == .thinking(answer: 1, upload: up))
    }

    @Test func a429EndsTheTurnWithoutRetry() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        let limited = RoundFailure.from(status: 429, code: "rate_limited", message: "At most 60 voice rounds per hour.")
        #expect(limited.kind == .rateLimited && !limited.retryable)
        #expect(limited.message == "At most 60 voice rounds per hour. Try again later.")
        #expect(m.uploadFailed(key: up.idempotencyKey, limited) == [.discard(key: up.idempotencyKey)])
        #expect(m.phase == .failed(answer: 1, failure: limited, upload: nil))
        #expect(m.retry() == [])
    }

    @Test func statusMapping() {
        #expect(RoundFailure.from(status: 401, code: "unauthorized", message: nil).kind == .notSignedIn)
        #expect(RoundFailure.from(status: 503, code: "reply_unconfigured", message: nil).kind == .notSetUp)
        #expect(!RoundFailure.from(status: 503, code: "reply_unconfigured", message: nil).retryable)
        #expect(RoundFailure.from(status: 502, code: "reply_failed", message: nil).retryable)
        #expect(!RoundFailure.from(status: 400, code: "unsupported_audio", message: "bad").retryable)
        #expect(RoundFailure.from(URLError(.notConnectedToInternet)) == .offline)
    }

    @Test func aSpeechFailureKeepsTheQuestionAndUsesTheWatchVoice() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1", question: "What is the one fact that backs that up?"))
        let reason = SpeechFailure.reason(for: SpeechFailure(status: 502, code: "speech_failed"))
        #expect(reason == "the coach voice failed (502)")
        #expect(m.speechFailed(roundID: "r1", reason: reason) == [.speakOnDevice("What is the one fact that backs that up?", .en)])
        guard case .replying(let shown) = m.phase else { Issue.record("not replying"); return }
        #expect(shown.question == "What is the one fact that backs that up?")
        #expect(shown.voice == .watch(reason: "the coach voice failed (502)"))
        #expect(shown.voice?.label == "Watch voice: the coach voice failed (502)")
        _ = m.speechFinished(roundID: "r1", at: t0.addingTimeInterval(9))
        #expect(m.phase.name == "your turn")
    }

    @Test func frenchSkipsTheSpeechFetch() {
        var m = SparringMachine(goalID: nil, language: .fr, newKey: Keys().next)
        let up = answer(&m, at: t0)
        #expect(up.language == .fr)
        let effects = m.replied(key: up.idempotencyKey, receipt("r1", question: "Quel fait précis appuie cela ?"))
        #expect(effects == [.discard(key: up.idempotencyKey), .speakOnDevice("Quel fait précis appuie cela ?", .fr)])
        #expect(!effects.contains { if case .fetchSpeech = $0 { true } else { false } })
    }

    @Test func anEmptyQuestionIsAFailure() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1", question: "  "))
        #expect(m.phase == .failed(answer: 1, failure: .noQuestion, upload: nil))
    }

    @Test func endRoundWithNoAnswersGoesBackToTheStart() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        _ = m.record(at: t0)
        #expect(m.endRound() == [.stopRecording(key: "key-1"), .discard(key: "key-1")])
        #expect(m.phase == .ready(answer: 1))
    }
}

@Suite struct Summary {
    @Test func pluralLabels() {
        #expect(RoundSummary.count(1, .hedge) == "1 unsure word")
        #expect(RoundSummary.count(2, .hedge) == "2 unsure words")
        #expect(RoundSummary.count(1, .filler) == "1 filler")
        #expect(RoundSummary.count(0, .restart) == "0 restarts")
    }

    @Test func picksTheBiggestDropElseTheMostUsed() {
        let a = VoiceMetrics(filler_count: 2, hedge_count: 3, restart_count: 0)
        let b = VoiceMetrics(filler_count: 2, hedge_count: 1, restart_count: 1)
        let s = RoundSummary.make([a, b])!
        #expect(s.habit == .hedge && s.first == 3 && s.last == 1 && s.unit == "unsure word" && s.comparison == "In your last answer, down from 3 in your first")
        let up = RoundSummary.make([VoiceMetrics(filler_count: 0, hedge_count: 0, restart_count: 0), VoiceMetrics(filler_count: 2, hedge_count: 1, restart_count: 0)])!
        #expect(up.habit == .filler && up.comparison == "In your last answer, up from 0 in your first" && up.unit == "fillers")
    }

    @Test func oneAnswerMakesNoComparisonAndTiesPickFillers() {
        let s = RoundSummary.make([VoiceMetrics(filler_count: 1, hedge_count: 1, restart_count: 1)])!
        #expect(s.habit == .filler && s.first == nil && s.comparison == "In your answer" && s.source == "Counted by the server in 1 answer")
        #expect(RoundSummary.make([]) == nil)
    }
}

@Suite struct Permission {
    @Test func micOffShowsTheReasonAndTryAgainRecords() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        #expect(m.refuse(.micOff) == [])
        #expect(m.phase == .failed(answer: 1, failure: .micOff, upload: nil))
        #expect(!RoundFailure.micOff.retryable)
        #expect(m.record(at: t0) == [.startRecording(key: "key-1")])
    }

    @Test func micOffDuringAQuestionStopsTheVoice() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next)
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1"))
        #expect(m.refuse(.micOff) == [.stopSpeech])
        #expect(m.phase == .failed(answer: 2, failure: .micOff, upload: nil))
    }
}

@Suite struct RoundEndOnServer {
    private func threeAnswers(_ m: inout SparringMachine) {
        var at = t0
        for n in 1...3 {
            let up = answer(&m, at: at)
            _ = m.replied(key: up.idempotencyKey, receipt("r\(n)", counterpart: Counterpart(reason: "open", answer: n)))
            at = at.addingTimeInterval(10)
            _ = m.speechFinished(roundID: "r\(n)", at: at)
            at = at.addingTimeInterval(1)
        }
    }

    @Test func endRoundAfterThreeAnswersTellsTheServerAndRecordAgainStartsAtOne() {
        let ends = Keys()
        var m = SparringMachine(goalID: "g1", language: .en, newKey: Keys().next, newEndKey: { "end-" + ends.next() })
        threeAnswers(&m)
        #expect(m.endRound() == [.endRoundOnServer(key: "end-key-1")])
        guard case .done = m.phase else { Issue.record("not done: \(m.phase.name)"); return }
        #expect(m.pendingEndKey == "end-key-1")
        // Not confirmed yet: Record again sends the same end first, then answer 1 of the new round.
        let again = m.record(at: t0.addingTimeInterval(60))
        guard case .recording(let n, let upload) = m.phase else { Issue.record("not recording"); return }
        #expect(n == 1)
        #expect(again == [.endRoundOnServer(key: "end-key-1"), .startRecording(key: upload.idempotencyKey)])
        #expect(upload.need == nil, "the need is chosen again for the new round")
        m.roundEndSent(key: "end-key-1")
        #expect(m.pendingEndKey == nil)
    }

    @Test func aConfirmedEndIsNotSentAgain() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next, newEndKey: { "end-1" })
        threeAnswers(&m)
        _ = m.endRound()
        m.roundEndSent(key: "end-1")
        let again = m.record(at: t0.addingTimeInterval(60))
        #expect(again.count == 1)
        guard case .startRecording = again.first else { Issue.record("expected only startRecording: \(again)"); return }
    }

    @Test func aWrapUpEndsTheRoundOnTheServerByItself() {
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next, newEndKey: { "end-1" })
        let up1 = answer(&m, at: t0)
        _ = m.replied(key: up1.idempotencyKey, receipt("r1"))
        _ = m.speechFinished(roundID: "r1", at: t0.addingTimeInterval(8))
        let up2 = answer(&m, at: t0.addingTimeInterval(9))
        _ = m.replied(key: up2.idempotencyKey, receipt("r2", move: "wrap_up", counterpart: Counterpart(reason: "measured_close", answer: 2)))
        #expect(m.speechFinished(roundID: "r2", at: t0.addingTimeInterval(20)) == [], "no end owed after a wrap-up")
        #expect(m.pendingEndKey == nil)
        #expect(m.record(at: t0.addingTimeInterval(30)).count == 1)
    }

    @Test func leavingMidRoundEndsItOnTheServerAndLeavingBeforeAnyReplyDoesNot() {
        var fresh = SparringMachine(goalID: nil, language: .en, newKey: Keys().next, newEndKey: { "end-1" })
        #expect(fresh.leave() == [])
        var m = SparringMachine(goalID: nil, language: .en, newKey: Keys().next, newEndKey: { "end-1" })
        let up = answer(&m, at: t0)
        _ = m.replied(key: up.idempotencyKey, receipt("r1"))
        #expect(m.leave() == [.endRoundOnServer(key: "end-1")])
    }
}

@Suite struct ScreenCardOnTheWrist {
    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }

    @Test func theGoalsRecentCardIsPickedElseAnUnlinkedOneNeverAnotherGoals() {
        let fresh = iso(t0.addingTimeInterval(-600)), stale = iso(t0.addingTimeInterval(-ScreenCard.maxAge - 60))
        let mine = ScreenCard(id: "card-goal", occurred_at: fresh, goal_id: "g1")
        let loose = ScreenCard(id: "card-loose", occurred_at: fresh, goal_id: nil)
        let other = ScreenCard(id: "card-other", occurred_at: fresh, goal_id: "g2")
        #expect(ScreenCard.pick(goalCard: mine, latest: other, goalID: "g1", now: t0) == "card-goal")
        #expect(ScreenCard.pick(goalCard: ScreenCard(id: "old", occurred_at: stale, goal_id: "g1"), latest: loose, goalID: "g1", now: t0) == "card-loose")
        #expect(ScreenCard.pick(goalCard: nil, latest: other, goalID: "g1", now: t0) == nil, "never another goal's card")
        #expect(ScreenCard.pick(goalCard: nil, latest: ScreenCard(id: "old", occurred_at: stale, goal_id: nil), goalID: "g1", now: t0) == nil, "too old")
        #expect(ScreenCard.pick(goalCard: nil, latest: other, goalID: nil, now: t0) == "card-other", "no goal selected: the latest card, as the Mac sends")
        #expect(ScreenCard.pick(goalCard: nil, latest: ScreenCard(id: "x", occurred_at: "2026-11-02T20:00:00Z", goal_id: nil), goalID: nil,
                                now: ISO8601DateFormatter().date(from: "2026-11-02T20:10:00Z")!) == "x", "whole-second timestamps parse too")
        #expect(ScreenCard.pick(goalCard: nil, latest: nil, goalID: "g1", now: t0) == nil)
    }

    @Test func theCardGoesWithEveryAnswerAndIsDroppedIfTheServerNoLongerHasIt() {
        var m = SparringMachine(goalID: "g1", language: .en, screenContextID: "card-goal", newKey: Keys().next)
        let first = answer(&m, at: t0)
        #expect(first.screenContextID == "card-goal")
        // Hidden on the Mac after the overview was read: the same answer, same key, goes again without the card.
        let effects = m.uploadFailed(key: first.idempotencyKey, RoundFailure.from(status: 404, code: "screen_context_not_found", message: "Screen card not found."))
        guard case .thinking(1, let again) = m.phase else { Issue.record("not thinking: \(m.phase.name)"); return }
        #expect(effects == [.upload(again)])
        #expect(again.idempotencyKey == first.idempotencyKey && again.screenContextID == nil && again.occurredAt == first.occurredAt)
        _ = m.replied(key: again.idempotencyKey, receipt("r1"))
        _ = m.speechFinished(roundID: "r1", at: t0.addingTimeInterval(9))
        #expect(answer(&m, at: t0.addingTimeInterval(10)).screenContextID == nil, "later answers go without it")
        // A 404 without a card is an ordinary failure.
        var plain = SparringMachine(goalID: "g1", language: .en, newKey: Keys().next)
        let up = answer(&plain, at: t0)
        _ = plain.uploadFailed(key: up.idempotencyKey, RoundFailure(kind: .serverError, message: "Record not found.", status: 404))
        guard case .failed = plain.phase else { Issue.record("expected a failure"); return }
    }

    @Test func aDeletedGoalIsNotMistakenForAHiddenCard() {
        var m = SparringMachine(goalID: "g-gone", language: .en, screenContextID: "card-goal", newKey: Keys().next)
        let up = answer(&m, at: t0)
        let goalGone = RoundFailure.from(status: 404, code: "not_found", message: "Record not found.")
        #expect(!goalGone.screenCardGone)
        #expect(m.uploadFailed(key: up.idempotencyKey, goalGone).allSatisfy { if case .upload = $0 { false } else { true } }, "no automatic resend")
        guard case .failed(1, let failure, _) = m.phase else { Issue.record("expected a failure: \(m.phase.name)"); return }
        #expect(failure.code == "not_found")
        #expect(m.screenContextID == "card-goal", "the card is kept")
    }
}
