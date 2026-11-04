import Foundation
import XCTest
@testable import ScreenContextCore

final class SemanticNativeCompatibility: XCTestCase {
    private func data(_ name: String) throws -> Data {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SEMANTIC_FIXTURES"])
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(values[name]))
    }
    private func receipt(_ name: String) throws -> VoiceRoundReceipt { try JSONDecoder().decode(VoiceRoundReceipt.self, from: data(name)) }

    func testActualBackendResponsesAndLiveFramesDecode() throws {
        for name in ["unclear", "partial", "addressed", "replay", "capped"] {
            let response = try receipt(name)
            XCTAssertNil(response.counterpart?.need)
            XCTAssertNil(response.counterpart?.need_met)
            XCTAssertNotEqual(response.counterpart?.reason, "measured_close")
        }
        for (name, expected) in [("liveReply", "reply"), ("liveSaved", "saved")] {
            let raw = String(decoding: try data(name), as: UTF8.self)
            let event = try XCTUnwrap(LiveVoiceEvent.decode(raw))
            switch event {
            case .reply(let r): XCTAssertEqual(expected, "reply"); XCTAssertEqual(r.counterpart?.reason, "semantic_open")
            case .saved(let r): XCTAssertEqual(expected, "saved"); XCTAssertEqual(r.counterpart?.reason, "semantic_open")
            default: XCTFail("wrong event")
            }
        }
    }
    func testCrossDeviceSecondAndThirdAnswerClearPriorLexicalNeedAndMet() throws {
        let legacy = try receipt("legacy")
        XCTAssertEqual(legacy.counterpart?.need, "date")
        XCTAssertEqual(legacy.counterpart?.need_met, true)
        for name in ["partial", "addressed", "replay"] {
            var need = RoundNeed()
            _ = need.record(legacy.counterpart, hedges: 0, answer: 1, endsRound: false)
            XCTAssertEqual(need.need, "date"); XCTAssertEqual(need.metOn, 1)
            let r = try receipt(name)
            // The compatibility answer is a reset sentinel; practice.answer retains the true server ordinal.
            XCTAssertEqual(r.counterpart?.answer, 1)
            let line = need.record(r.counterpart, hedges: r.metrics?.hedge_count, answer: try XCTUnwrap(r.counterpart?.answer), endsRound: r.reply.kind == .wrap_up)
            XCTAssertNil(line); XCTAssertNil(need.need); XCTAssertNil(need.metOn)
        }
    }
    func testTerminalAndUncertainTransitionsUseActualTurnMachine() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["unclear", "partial", "addressed", "capped"] {
            let r = try receipt(name), ends = ["addressed", "capped"].contains(name)
            var machine = VoiceTurnMachine(newKey: { "fixture-key" })
            _ = machine.keyDown(at: at); _ = machine.keyUp(at: at.addingTimeInterval(2))
            _ = machine.replyReady(key: "fixture-key", question: r.reply.question, endsRound: r.reply.kind == .wrap_up)
            guard case .speaking(_, _, let terminal) = machine.phase else { return XCTFail("not speaking") }
            XCTAssertEqual(terminal, ends)
            _ = machine.speechFinished(at: at.addingTimeInterval(4))
            XCTAssertEqual(machine.promptEndedAt == nil, ends)
            if ends { XCTAssertFalse(r.reply.question.contains("?")) }
        }
    }
    func testClosedRoundConflictIsNotRetryableOnMac() throws {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data("closed409")) as? [String: Any])
        XCTAssertEqual(raw["status"] as? Int, 409)
        let body = try XCTUnwrap(raw["body"] as? [String: Any])
        let code = try XCTUnwrap(body["error"] as? String), message = try XCTUnwrap(body["message"] as? String)
        XCTAssertEqual(code, "practice_closed"); XCTAssertTrue(message.contains("revise"))
        XCTAssertFalse(VoiceRoundUploader.isRetryable(.server(409, code, message)))
    }
}
