import XCTest
@testable import ScreenContextCore

/// The other person's need on this Mac: held for one round, sent back with each answer, and the card line at the wrap-up.
final class NeedLineTests: XCTestCase {
    private func c(_ need: String?, met: Bool?, answer: Int, mode: String = "model") -> VoiceCounterpart {
        VoiceCounterpart(need: need, need_met: met, reason: "open", answer: answer, reply_mode: mode)
    }

    func testTheNeedIsHeldForTheRoundAndDroppedAtTheWrapUp() {
        var round = RoundNeed()
        XCTAssertNil(round.need)
        XCTAssertEqual(round.record(c("date", met: false, answer: 1), hedges: 1, answer: 1, endsRound: false), "Need: a date")
        XCTAssertEqual(round.need, "date", "sent back with answer 2")
        XCTAssertEqual(round.record(c("date", met: true, answer: 2), hedges: 0, answer: 2, endsRound: true), "Need: a date · met on answer 2 · unsure words 1\u{00A0}→\u{00A0}0")
        XCTAssertNil(round.need, "dropped when the round ends")
    }

    func testANeedNotMetByTheCapSaysSo() {
        var round = RoundNeed()
        _ = round.record(c("owner", met: false, answer: 1), hedges: 2, answer: 1, endsRound: false)
        for answer in 2...3 { _ = round.record(c("owner", met: false, answer: answer), hedges: 1, answer: answer, endsRound: false) }
        XCTAssertEqual(round.record(c("owner", met: false, answer: 4), hedges: 1, answer: 4, endsRound: true), "Need: an owner · not met in 4 answers · unsure words 2\u{00A0}→\u{00A0}1")
    }

    func testOnlyTheFirstNamedNeedCountsAndAnUnknownWordIsIgnored() {
        var round = RoundNeed()
        _ = round.record(c("vibes", met: nil, answer: 1), hedges: 1, answer: 1, endsRound: false)
        XCTAssertNil(round.need)
        var named = RoundNeed()
        _ = named.record(c("number", met: false, answer: 1), hedges: 1, answer: 1, endsRound: false)
        _ = named.record(c("date", met: true, answer: 2), hedges: 0, answer: 2, endsRound: false)
        XCTAssertEqual(named.need, "number", "a later need does not replace the round's")
    }

    func testAnswerOneStartsANewRoundAndARoundWithoutANeedHasNoLine() {
        var round = RoundNeed()
        _ = round.record(c("date", met: false, answer: 1), hedges: 1, answer: 1, endsRound: false)
        // The server counted a new practice round (for example after 15 minutes): the old need goes.
        XCTAssertEqual(round.record(c("example", met: false, answer: 1), hedges: 0, answer: 1, endsRound: false), "Need: an example")
        var none = RoundNeed()
        XCTAssertNil(none.record(c(nil, met: nil, answer: 1), hedges: 1, answer: 1, endsRound: false))
        XCTAssertNil(none.record(nil, hedges: 0, answer: 2, endsRound: true), "a replayed receipt has no counterpart")
    }

    func testPhrases() {
        XCTAssertEqual(RoundNeed.needs.map(RoundNeed.phrase), ["a number", "a date", "a decision", "an owner", "an example"])
        XCTAssertEqual(RoundNeed.codeOnlyLine, "Code-only question (no model)")
        XCTAssertEqual(RoundNeed.source(endsRound: false, model: "Muse Spark Open"), "picked by Muse Spark Open from your card")
        XCTAssertEqual(RoundNeed.source(endsRound: true, model: "Muse Spark Open"), "need picked by Muse Spark Open · met and counts measured by code")
    }

    func testTheReceiptAndTheLiveReplyDecodeTheCounterpartAndACodeOnlyReplyHasNoModel() throws {
        let body = #"{"round_id":"r1","receipt_id":"rc","replayed":false,"transcript":"I think.","reply":{"move":"challenge","question":"q"},"model":null,"counterpart":{"need":null,"need_met":null,"allowed":["follow_up","challenge"],"reason":"open","answer":1,"reply_mode":"code"}}"#
        let receipt = try JSONDecoder().decode(VoiceRoundReceipt.self, from: Data(body.utf8))
        XCTAssertNil(receipt.model)
        XCTAssertEqual(receipt.counterpart?.isCodeOnly, true)
        XCTAssertEqual(receipt.counterpart?.allowed, ["follow_up", "challenge"])
        let live = #"{"type":"reply","round_id":"r2","transcript":"By March 14.","reply":{"move":"wrap_up","question":"Thanks."},"model":"meta-models/muse-spark-open-1026","counterpart":{"need":"date","need_met":true,"allowed":["wrap_up"],"reason":"measured_close","answer":2,"reply_mode":"model"}}"#
        guard case .reply(let reply)? = LiveVoiceEvent.decode(live) else { return XCTFail("reply event") }
        XCTAssertEqual(reply.counterpart?.reason, "measured_close"); XCTAssertEqual(reply.counterpart?.need, "date")
        // An older server sends neither field.
        XCTAssertNil(try JSONDecoder().decode(VoiceRoundReceipt.self, from: Data(voiceReceiptJSON.utf8)).counterpart)
    }

    func testTheNeedAndTheReplyModeGoInTheStartFrameOnlyWhenSet() throws {
        var round = VoiceRoundRequest(wav: Data(), idempotencyKey: "voice-need-1")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LiveStart(round))) as! [String: Any]
        XCTAssertNil(plain["need"]); XCTAssertNil(plain["reply_mode"])
        round.need = "date"; round.replyMode = "code"
        let start = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LiveStart(round))) as! [String: Any]
        XCTAssertEqual(start["need"] as? String, "date"); XCTAssertEqual(start["reply_mode"] as? String, "code")
    }
}

final class NeedHeaderTests: XCTestCase {
    func testTheUploadSendsTheNeedAndTheReplyModeOnlyWhenSet() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SequenceProtocol.self]
        let api = CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "local-test-token", session: URLSession(configuration: configuration))
        SequenceProtocol.requests = []; SequenceProtocol.bodies = []
        SequenceProtocol.answers = [.status(200, voiceReceiptJSON), .status(200, voiceReceiptJSON)]
        var round = VoiceRoundRequest(wav: WAV.encode([0, 1]), idempotencyKey: "voice-need-2")
        _ = try await api.postVoiceRound(round)
        round.need = "owner"; round.replyMode = "code"
        _ = try await api.postVoiceRound(round)
        XCTAssertNil(SequenceProtocol.requests[0].value(forHTTPHeaderField: "X-Counterpart-Need"))
        XCTAssertNil(SequenceProtocol.requests[0].value(forHTTPHeaderField: "X-Reply-Mode"))
        XCTAssertEqual(SequenceProtocol.requests[1].value(forHTTPHeaderField: "X-Counterpart-Need"), "owner")
        XCTAssertEqual(SequenceProtocol.requests[1].value(forHTTPHeaderField: "X-Reply-Mode"), "code")
    }
}
