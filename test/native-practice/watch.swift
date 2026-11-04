import Foundation
import XCTest
@testable import SparringCore

final class SemanticNativeCompatibility: XCTestCase {
    private func data(_ name: String) throws -> Data {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SEMANTIC_FIXTURES"])
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(values[name]))
    }
    private func receipt(_ name: String) throws -> VoiceRoundReceipt { try JSONDecoder().decode(VoiceRoundReceipt.self, from: data(name)) }
    private func turn(_ m: inout SparringMachine, _ r: VoiceRoundReceipt, at: Date) throws -> SparringMachine.Shown {
        _ = m.record(at: at); _ = m.stop(at: at.addingTimeInterval(2)); _ = m.replied(key: "fixture-key", r)
        guard case .replying(let shown) = m.phase else { throw NSError(domain: "not replying", code: 1) }
        _ = m.speechFinished(roundID: r.round_id, at: at.addingTimeInterval(4))
        return shown
    }
    func testCleanRoundAcceptsUnclearPartialAndAddressedWithoutMeasuredSuccess() throws {
        var m = SparringMachine(goalID: "goal-semantic", language: .en, newKey: { "fixture-key" })
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, name) in ["unclear", "partial", "addressed"].enumerated() {
            let r = try receipt(name)
            XCTAssertNil(r.counterpart?.need); XCTAssertNil(r.counterpart?.need_met)
            let shown = try turn(&m, r, at: start.addingTimeInterval(Double(i*10)))
            XCTAssertEqual(shown.endsRound, name == "addressed")
            XCTAssertNotEqual(shown.closedBy, "measured_close")
        }
        guard case .done(_, _, _, let reason) = m.phase else { return XCTFail("not done") }
        XCTAssertEqual(reason, "model_assessed_addressed"); XCTAssertNil(m.need)
    }
    func testCapAndReplayDecodeAndEndWithDistinctReasons() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["capped", "replay"] {
            var m = SparringMachine(goalID: "goal-semantic", language: .en, newKey: { "fixture-key" })
            let r = try receipt(name), shown = try turn(&m, r, at: start)
            XCTAssertTrue(shown.endsRound)
            XCTAssertEqual(shown.closedBy, name == "capped" ? "answer_cap" : "model_assessed_addressed")
            XCTAssertFalse(shown.question.contains("?"))
        }
    }
    func testFreshLocalRoundClearsLegacyNeedBeforeSemanticOptIn() throws {
        var m = SparringMachine(goalID: "goal-semantic", language: .en, newKey: { "fixture-key" })
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try turn(&m, receipt("legacy"), at: start)
        XCTAssertEqual(m.need, "date")
        _ = m.endRound()
        let shown = try turn(&m, receipt("partial"), at: start.addingTimeInterval(10))
        XCTAssertNil(m.need); XCTAssertEqual(shown.answer, 1); XCTAssertFalse(shown.endsRound)
        XCTAssertEqual(m.answered, 1)
    }
    func testKnownMixedRoundLimitRemainsExplicitUntilNativeMigration() throws {
        var m = SparringMachine(goalID: "goal-semantic", language: .en, newKey: { "fixture-key" })
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 { _ = try turn(&m, receipt("legacy"), at: start.addingTimeInterval(Double(i*10))) }
        let r = try receipt("unclear"), shown = try turn(&m, r, at: start.addingTimeInterval(40))
        XCTAssertEqual(r.reply.move, "follow_up")
        XCTAssertTrue(shown.endsRound, "Existing watch locally caps at4 even when server semantic round is open. Require a fresh local round.")
        guard case .done = m.phase else { return XCTFail("expected existing local cap behavior") }
    }
    func testClosedRoundConflictPreservesServerMessageAndExactRetryKey() throws {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data("closed409")) as? [String: Any])
        let body = try XCTUnwrap(raw["body"] as? [String: Any])
        let failure = RoundFailure.from(status: try XCTUnwrap(raw["status"] as? Int), code: body["error"] as? String, message: body["message"] as? String)
        XCTAssertTrue(failure.message.contains("revise")); XCTAssertTrue(failure.retryable)
        var m = SparringMachine(goalID: "goal-semantic", language: .en, newKey: { "fixture-key" })
        let start = Date(); _ = m.record(at: start); _ = m.stop(at: start.addingTimeInterval(2)); _ = m.uploadFailed(key: "fixture-key", failure)
        let effects = m.retry()
        guard case .upload(let upload) = effects.first else { return XCTFail("missing retry") }
        XCTAssertEqual(upload.idempotencyKey, "fixture-key")
    }
}
