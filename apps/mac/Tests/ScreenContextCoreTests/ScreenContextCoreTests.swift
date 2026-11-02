import CoreGraphics
import Foundation
import XCTest
@testable import ScreenContextCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Fixtures").standardized

/// Every personal value planted in the synthetic fixture. None may survive redaction.
private let planted = ["Dana", "Whitfield", "dana.whitfield", "example.com", "555-0199", "555", "0199", "416",
                       "4111", "046 454 286", "454", "a8F3kQ92", "docs.example", "token=", "200 King", "King Street", "M5H", "3T4"]

private func assertNoPlanted(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    for value in planted { XCTAssertFalse(text.contains(value), "planted value survived: \(value)", file: file, line: line) }
}

final class RedactorTests: XCTestCase {
    func testFixtureTextLosesEveryPlantedValue() throws {
        let original = try String(contentsOf: fixtures.appending(path: "meeting-prep.txt"), encoding: .utf8)
        let result = Redactor().redact(original)
        assertNoPlanted(result.text)
        for kind in [RedactionKind.person, .email, .phone, .number, .link, .address] {
            XCTAssertGreaterThan(result.counts[kind] ?? 0, 0, "no \(kind) placeholder")
        }
        XCTAssertTrue(result.text.contains("ask to own the Q1 launch"), "ordinary content is kept")
        XCTAssertTrue(result.text.contains("Support tickets down 18% since September"))
        XCTAssertTrue(result.text.contains("Thursday 3:00 pm"), "times are not numbers to redact")
    }

    func testEachKindBecomesATypedPlaceholder() {
        let cases: [(String, RedactionKind)] = [
            ("Write to sam.lee@example.org today", .email),
            ("Call +1 (416) 555-0199 now", .phone),
            ("Call 416.555.0199 now", .phone),
            ("Card 4111-1111-1111-1111 on file", .number),
            ("SIN 046 454 286 on file", .number),
            ("SSN 078-05-1120 on file", .number),
            ("Account 12345678 closed", .number),
            ("IBAN GB82 WEST 1234 5698 7654 32 here", .number),
            ("See https://example.com/doc?token=abc123 for it", .link),
            ("See docs.example.com/page for it", .link),
            ("Office at 200 King Street West downtown", .address),
            ("Postal code M5H 3T4 please", .address),
        ]
        for (input, kind) in cases {
            let result = Redactor().redact(input)
            XCTAssertTrue(result.text.contains(kind.placeholder), "\(input) → \(result.text)")
            XCTAssertGreaterThan(result.counts[kind] ?? 0, 0, input)
        }
    }

    func testNamesArePropagatedAndPlaceholdersAreNotReRedacted() {
        let result = Redactor().redact("1:1 with Priya Raman on Monday. Priya's draft is attached. Raman agreed.")
        XCTAssertFalse(result.text.contains("Priya")); XCTAssertFalse(result.text.contains("Raman"))
        XCTAssertEqual(Redactor().redact(result.text).text, result.text, "redacting twice changes nothing")
    }

    func testCleanTextIsUnchanged() {
        let text = "Goal: lead with the ask. Q1 2026 plan, room 4B at 10:30, 18% fewer tickets."
        XCTAssertEqual(Redactor().redact(text).text, text)
    }
}

final class FixtureImageTests: XCTestCase {
    func testOCRThenRedactionOnTheFixturePNGLeavesNoPlantedData() throws {
        let image = try ImageLoading.cgImage(at: fixtures.appending(path: "meeting-prep.png"))
        let ocr = try VisionTextReader().read(image)
        XCTAssertTrue(ocr.contains("Q1 launch"), "OCR read the fixture: \(ocr.prefix(80))")
        XCTAssertTrue(ocr.contains("Whitfield"), "the fixture really contains the planted name before redaction")
        let redacted = Redactor().redact(ocr)
        assertNoPlanted(redacted.text)
        XCTAssertGreaterThanOrEqual(redacted.total, 8)
    }

    func testPipelineWritesNothingToTheTemporaryDirectory() async throws {
        let temp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
        let image = try ImageLoading.cgImage(at: fixtures.appending(path: "meeting-prep.png"))
        let pipeline = ScreenContextPipeline(capturer: FixedCapture(image: image), reader: VisionTextReader())
        let result = try await pipeline.run(app: textEdit, secureInput: false)
        assertNoPlanted(result.redacted.text)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
        XCTAssertEqual(after.subtracting(before), [], "no screenshot or text file was written")
    }
}

private let textEdit = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", processID: 1)

private final class CountingCapture: WindowCapturing, @unchecked Sendable {
    var calls = 0
    func capture(_ app: FrontApp) async throws -> CapturedWindow { calls += 1; throw CaptureError.noWindow }
}

private struct FixedCapture: WindowCapturing {
    let image: CGImage
    func capture(_ app: FrontApp) async throws -> CapturedWindow { CapturedWindow(image: image, app: app) }
}

final class GateTests: XCTestCase {
    func testDenyListAndSecureInputBlockBeforeCapture() async {
        let capture = CountingCapture()
        let pipeline = ScreenContextPipeline(capturer: capture)
        for app in [FrontApp(name: "1Password", bundleID: "com.1password.1password", processID: 2),
                    FrontApp(name: "Messages", bundleID: "com.apple.MobileSMS", processID: 3),
                    FrontApp(name: "Coach", bundleID: "com.zencronic.commscoach.mac", processID: 4)] {
            do { _ = try await pipeline.run(app: app, secureInput: false); XCTFail("should block \(app.name)") }
            catch { XCTAssertEqual(error as? CaptureError, .blocked(app.name)) }
        }
        do { _ = try await pipeline.run(app: textEdit, secureInput: true); XCTFail("secure input should block") }
        catch { XCTAssertEqual(error as? CaptureError, .blocked("a password field")) }
        XCTAssertEqual(capture.calls, 0, "no pixels were captured for a blocked app")
        XCTAssertEqual(CaptureGate().check(textEdit, secureInput: false), .allowed)
    }
}

final class PayloadTests: XCTestCase {
    private func payload(_ text: String) -> ScreenContextPayload? {
        ScreenContextPayload.make(redacted: RedactionResult(text: text, counts: [.person: 1]), appName: "TextEdit", goalID: "goal-1", purpose: .meeting_prep)
    }

    func testOversizedTextIsTrimmedToFitEveryLimit() throws {
        for text in [String(repeating: "word ", count: 5000), String(repeating: "€", count: 9000), String(repeating: "é ", count: 4000)] {
            let p = try XCTUnwrap(payload(text))
            XCTAssertLessThanOrEqual(p.text.count, ScreenContextPayload.maxTextCharacters)
            XCTAssertLessThanOrEqual(p.text.utf8.count, ScreenContextPayload.maxTextBytes)
            XCTAssertLessThanOrEqual(try p.encoded().count, ScreenContextPayload.maxBodyBytes)
        }
    }

    func testPayloadCarriesTextAndLabelsOnlyNoImageBytes() throws {
        let p = try XCTUnwrap(payload("1:1 with [person]: lead with the ask."))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["goal_id", "language", "capture_device", "purpose", "occurred_at", "app_name", "text", "redaction"])
        XCTAssertEqual(json["capture_device"] as? String, "mac")
        XCTAssertEqual((json["redaction"] as? [String: Any])?["method"] as? String, "on-device-v1")
        let fieldTypes = Mirror(reflecting: p).children.map { String(describing: type(of: $0.value)) }
        XCTAssertEqual(Set(fieldTypes), ["Optional<String>", "String", "Purpose", "Redaction"], "no Data or image fields exist")
        let image = try Data(contentsOf: fixtures.appending(path: "meeting-prep.png"))
        let body = try p.encoded()
        XCTAssertNil(body.range(of: image.prefix(8)), "no PNG bytes"); XCTAssertNil(String(decoding: body, as: UTF8.self).range(of: "iVBORw0KGgo"), "no base64 PNG")
    }

    func testEmptyTextGivesNoPayloadAndAppNameIsSanitised() {
        XCTAssertNil(payload("   \n "))
        let p = ScreenContextPayload.make(redacted: RedactionResult(text: "x", counts: [:]), appName: "Text\nEdit" + String(repeating: "a", count: 100), goalID: nil, purpose: .reading)
        XCTAssertEqual(p?.app_name?.count, 80); XCTAssertFalse(p?.app_name?.contains("\n") ?? true)
        XCTAssertNil(p?.goal_id)
    }
}

final class NudgeDiffTests: XCTestCase {
    private func state(_ revision: String, pending: Int = 0, version: Int = 1, measurement: String? = nil, device: String? = nil) -> ObservedState {
        ObservedState(revision: revision, goals: ["g1": .init(title: "Answer clearly", version: version, pending: pending,
                                                                latestMeasurementID: measurement, latestMeasurementDevice: device)])
    }

    func testANewPendingExerciseNudges() {
        XCTAssertEqual(NudgeDiff.changes(from: state("a"), to: state("b", pending: 1)), [.exerciseAdded(goalID: "g1", goalTitle: "Answer clearly")])
    }

    func testSameRevisionOrFirstPollNeverNudges() {
        XCTAssertEqual(NudgeDiff.changes(from: state("a"), to: state("a", pending: 1)), [])
        XCTAssertEqual(NudgeDiff.changes(from: nil, to: state("a", pending: 3)), [])
    }

    func testGoalRevisionAndWatchCaptureNudgeButOwnMacCaptureDoesNot() {
        XCTAssertEqual(NudgeDiff.changes(from: state("a"), to: state("b", version: 2)), [.goalRevised(goalID: "g1", goalTitle: "Answer clearly")])
        XCTAssertEqual(NudgeDiff.changes(from: state("a"), to: state("b", measurement: "s1", device: "watch")), [.newCapture(goalID: "g1", goalTitle: "Answer clearly", device: "watch")])
        XCTAssertEqual(NudgeDiff.changes(from: state("a"), to: state("b", measurement: "s2", device: "mac")), [])
        XCTAssertEqual(NudgeDiff.changes(from: state("a"), to: state("b")), [], "a screen context of our own changes only the revision")
    }

    func testNewestPendingExerciseIsChosen() {
        let goal = GoalSummary(id: "g1", version: 1, title: "t", target: "t", progress: GoalProgress(pending_exercises: 2, measured_sessions: 0, screen_contexts: 0), latest_measurement: nil)
        let context = GoalContext(goal: goal, exercises: [
            Exercise(id: "e1", goal_id: "g1", title: "Old", instructions: "i", updated_at: "2026-11-01T10:00:00Z"),
            Exercise(id: "e2", goal_id: "g1", title: "Done", instructions: "i", updated_at: "2026-11-02T10:00:00Z"),
            Exercise(id: "e3", goal_id: "g1", title: "State the ask in one sentence", instructions: "i", updated_at: "2026-11-01T12:00:00Z"),
        ], check_ins: [CheckIn(exercise_id: "e2")])
        XCTAssertEqual(context.newestPending?.title, "State the ask in one sentence")
    }
}

/// Answers every request from memory and records what the client sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var reply: (Int, String) = (200, "{}")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close(); Self.bodies.append(data)
        } else { Self.bodies.append(request.httpBody ?? Data()) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CoachAPITests: XCTestCase {
    private func api() -> CoachAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "local-test-token", session: URLSession(configuration: configuration))
    }

    override func setUp() { StubProtocol.requests = []; StubProtocol.bodies = [] }

    func testPostSendsAuthIdempotencyAndJSONAndDecodesTheReceipt() async throws {
        StubProtocol.reply = (200, #"{"receipt_id":"r1","replayed":false,"record_version":1,"saved":true,"record":{"id":"s1","version":1,"app_name":"TextEdit","goal_id":"g1","text_retained":false,"pixels_sent":false,"extra":1,"analysis":{"status":"model_observation","summary":"s","observation":"o","next_step":"n","model":"m"}}}"#)
        let payload = try XCTUnwrap(ScreenContextPayload.make(redacted: RedactionResult(text: "Lead with [person]'s ask.", counts: [.person: 1]), appName: "TextEdit", goalID: "g1", purpose: .meeting_prep))
        let receipt = try await api().postScreenContext(payload, idempotencyKey: "mac-test-0001")
        XCTAssertEqual(receipt.receipt_id, "r1"); XCTAssertEqual(receipt.record.analysis.next_step, "n"); XCTAssertFalse(receipt.record.text_retained)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/screen-contexts"); XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "mac-test-0001")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubProtocol.bodies.first)) as? [String: Any])
        XCTAssertEqual(sent["text"] as? String, "Lead with [person]'s ask.")
    }

    func testServerErrorsAreTypedAndRetryability() async {
        StubProtocol.reply = (429, #"{"error":"rate_limited","message":"At most 30 screen contexts per hour."}"#)
        do { _ = try await api().overview(); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? CoachError, .server(429, "rate_limited", "At most 30 screen contexts per hour."))
            XCTAssertTrue((error as? CoachError)?.isRetryable ?? false)
        }
        XCTAssertFalse(CoachError.server(400, "invalid_value", "x").isRetryable)
    }

    func testOverviewDecodesTheLiveShape() async throws {
        StubProtocol.reply = (200, #"{"as_of":"2026-11-02T04:53:00Z","snapshot_revision":"rev","request_id":"q","goals":[{"id":"g1","version":2,"title":"Answer clearly","target":"t","updated_at":"x","progress":{"assigned_exercises":1,"pending_exercises":1,"self_reported_completions":0,"skipped_exercises":0,"measured_sessions":1,"screen_contexts":1,"measured_improvement":null},"latest_feedback":null,"latest_measurement":{"id":"s","capture_device":"watch"},"latest_screen_context":null}],"latest_screen_context":{"id":"c1","version":1,"app_name":"TextEdit","goal_id":"g1","summary":"s","observation":"o","next_step":"n"}}"#)
        let overview = try await api().overview()
        XCTAssertEqual(ObservedState(overview).goals["g1"]?.pending, 1)
        XCTAssertEqual(overview.latest_screen_context?.id, "c1")
    }
}
