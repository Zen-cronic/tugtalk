import XCTest
@testable import ScreenContextCore

final class KeepRecordingsTests: XCTestCase {
    private func api() -> CoachAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SequenceProtocol.self]
        return CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "local-test-token", session: URLSession(configuration: configuration))
    }

    override func setUp() { SequenceProtocol.requests = []; SequenceProtocol.bodies = []; SequenceProtocol.answers = [] }

    private let settingsJSON = #"{"settings":{"keep_recordings":false,"label":"Keep my recordings","version":1,"updated_at":null,"kept":{"recordings":0,"bytes":0,"cap_bytes":200000000}},"request_id":"r"}"#

    func testANewAccountReadsOff() async throws {
        SequenceProtocol.answers = [.status(200, settingsJSON)]
        let settings = try await api().settings()
        XCTAssertFalse(settings.keep_recordings)
        XCTAssertEqual(settings.version, 1)
        XCTAssertEqual(settings.kept, KeptCounts(recordings: 0, bytes: 0, cap_bytes: 200_000_000))
        XCTAssertEqual(SequenceProtocol.requests.first?.url?.path, "/v1/settings")
    }

    func testTurningOnSendsAVersionedIdempotentPatch() async throws {
        SequenceProtocol.answers = [.status(200, #"{"receipt_id":"rc","record_version":2,"settings":{"keep_recordings":true,"version":2,"kept":{"recordings":0,"bytes":0,"cap_bytes":200000000}}}"#)]
        let saved = try await api().setKeepRecordings(true, deleteKept: true, expectedVersion: 1, idempotencyKey: "mac-keep-1")
        XCTAssertTrue(saved.keep_recordings); XCTAssertEqual(saved.version, 2)
        let request = try XCTUnwrap(SequenceProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH"); XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "mac-keep-1")
        XCTAssertEqual(String(decoding: SequenceProtocol.bodies[0], as: UTF8.self), #"{"expected_version":1,"keep_recordings":true}"#,
                       "delete is never sent while turning it on")
    }

    func testTurnOffAndDeleteSendsTheDeleteFlag() throws {
        XCTAssertEqual(String(decoding: try CoachAPI.settingsPatch(keep: false, deleteKept: true, expectedVersion: 4), as: UTF8.self),
                       #"{"delete_kept_recordings":true,"expected_version":4,"keep_recordings":false}"#)
        XCTAssertEqual(String(decoding: try CoachAPI.settingsPatch(keep: false, deleteKept: false, expectedVersion: 4), as: UTF8.self),
                       #"{"expected_version":4,"keep_recordings":false}"#)
    }

    func testAVoiceRoundSaysWhetherItsRecordingWasKept() throws {
        let off = try JSONDecoder().decode(VoiceRoundReceipt.self, from: Data(voiceReceiptJSON.utf8))
        XCTAssertNil(off.media, "with the setting off the reply has no media block")
        let keptJSON = voiceReceiptJSON.replacingOccurrences(of: #""extra":true"#, with: #""media":{"kept":true,"kind":"audio","bytes":3200,"sha256":"ab","content_type":"audio/wav","kept_at":"t"}"#)
        XCTAssertEqual(try JSONDecoder().decode(VoiceRoundReceipt.self, from: Data(keptJSON.utf8)).media?.note, "Recording kept")
        let full = try JSONDecoder().decode(KeptMedia.self, from: Data(#"{"kept":false,"kind":"audio","reason":"full","message":"m"}"#.utf8))
        XCTAssertEqual(full.note, "Recording not kept: storage full")
        XCTAssertNil(try JSONDecoder().decode(KeptMedia.self, from: Data(#"{"kept":false,"kind":"audio","deleted_at":"t"}"#.utf8)).note)
    }

    func testTheDownloadIsTheRawAudio() async throws {
        SequenceProtocol.answers = [.status(200, "RIFF-not-json")]
        let data = try await api().downloadKeptRecording(id: "s1")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "RIFF-not-json")
        XCTAssertEqual(SequenceProtocol.requests.first?.url?.path, "/v1/media/s1")
        SequenceProtocol.answers = [.status(404, #"{"error":"not_found"}"#)]
        do { _ = try await api().downloadKeptRecording(id: "other"); XCTFail("a 404 throws") } catch let error as CoachError {
            if case .server(404, _, _) = error {} else { XCTFail("\(error)") }
        }
    }

    func testTheSummaryIsPlain() {
        XCTAssertEqual(KeepRecordingsCopy.summary(KeptCounts(recordings: 3, bytes: 1_234_567, cap_bytes: 200_000_000)), "3 kept · 1.2 MB")
        XCTAssertEqual(KeepRecordingsCopy.size(52_400_000), "52 MB")
        XCTAssertEqual(KeepRecordingsCopy.label, "Keep my recordings")
    }
}
