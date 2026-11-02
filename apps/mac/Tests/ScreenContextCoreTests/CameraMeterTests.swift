import Foundation
import XCTest
@testable import ScreenContextCore

final class CameraMeterTests: XCTestCase {
    /// Frames at 10 a second: `facing` true = head at 0°, false = head down at the notes (-35° pitch).
    private func frames(_ pattern: [(seconds: Double, facing: Bool)], start: Double = 0) -> [HeadPoseSample] {
        var t = start, out: [HeadPoseSample] = []
        for part in pattern {
            for _ in 0..<Int((part.seconds * 10).rounded()) {
                out.append(HeadPoseSample(t: t, yaw: 0, pitch: part.facing ? 0 : -35))
                t += 0.1
            }
        }
        return out
    }

    func testTheConeIsYawAndPitchBothInside() {
        let rule = FacingRule.standard
        XCTAssertEqual(rule.maxYaw, 20)
        XCTAssertEqual(rule.maxPitch, 15)
        XCTAssertTrue(rule.faces(HeadPoseSample(t: 0, yaw: 0, pitch: 0)))
        XCTAssertTrue(rule.faces(HeadPoseSample(t: 0, yaw: -20, pitch: 15)), "the edge counts as facing")
        XCTAssertTrue(rule.faces(HeadPoseSample(t: 0, yaw: 19.9, pitch: -14.9)))
        XCTAssertFalse(rule.faces(HeadPoseSample(t: 0, yaw: 20.1, pitch: 0)), "turned to the side")
        XCTAssertFalse(rule.faces(HeadPoseSample(t: 0, yaw: 0, pitch: -15.1)), "tilted down to notes")
        XCTAssertFalse(rule.faces(HeadPoseSample(t: 0, yaw: 0, pitch: 40)))
        XCTAssertFalse(rule.faces(HeadPoseSample(t: 0, yaw: nil, pitch: nil)), "no face is not facing")
        XCTAssertFalse(rule.faces(HeadPoseSample(t: 0, yaw: 0, pitch: nil)), "no pitch is not facing")
        XCTAssertFalse(rule.faces(HeadPoseSample(t: 0, yaw: .nan, pitch: 0)))
        XCTAssertTrue(FacingRule(maxYaw: 30, maxPitch: 25).faces(HeadPoseSample(t: 0, yaw: 25, pitch: -20)))
    }

    func testPercentCountAndLongestForNotesBelowTheScreen() throws {
        // 6 s facing, 2 s at the notes, four times: 75%, 4 look-aways of 2 s.
        let samples = frames(Array(repeating: [(6.0, true), (2.0, false)], count: 4).flatMap { $0 })
        let m = try XCTUnwrap(CameraMeter.measure(samples, end: 32))
        XCTAssertEqual(m, CameraMetrics(faced_camera_pct: 75, looked_away_count: 4, longest_look_away_ms: 2000, frames: 320))
        XCTAssertEqual(m.facedLine, "Faced the camera 75% of your answer")
        XCTAssertEqual(m.lookedAwayLine, "Looked away 4 times")
        XCTAssertEqual(m.longestLine, "longest 2.0\u{00A0}s")
    }

    func testGlancesShorterThanASecondAreNotCountedButLowerThePercent() throws {
        let samples = frames([(3, true), (0.5, false), (3, true), (0.8, false), (3, true)])
        let m = try XCTUnwrap(CameraMeter.measure(samples, end: 10.3))
        XCTAssertEqual(m.looked_away_count, 0)
        XCTAssertEqual(m.longest_look_away_ms, 0)
        XCTAssertEqual(m.faced_camera_pct, 87, "13 of 103 frames away")
        XCTAssertEqual(m.lookedAwayLine, "Didn't look away")
        XCTAssertNil(m.longestLine)
    }

    func testExactlyOneSecondCountsAndTheLongestIsTheLongest() throws {
        let samples = frames([(2, true), (1, false), (2, true), (3.5, false), (2, true)])
        let m = try XCTUnwrap(CameraMeter.measure(samples, end: 10.5))
        XCTAssertEqual(m.looked_away_count, 2)
        XCTAssertEqual(m.longest_look_away_ms, 3500)
        XCTAssertEqual(m.lookedAwayLine, "Looked away 2 times")
    }

    func testAFlickerBackToTheCameraDoesNotSplitALookAway() throws {
        // 3 s away with one stray facing frame in the middle: one look-away of 3 s, not two.
        var samples = frames([(2, true), (3, false), (2, true)])
        samples[35].pitch = 0
        let m = try XCTUnwrap(CameraMeter.measure(samples, end: 7))
        XCTAssertEqual(m.looked_away_count, 1)
        XCTAssertEqual(m.longest_look_away_ms, 3000)
    }

    func testAStrayAwayFrameWhileFacingIsIgnored() throws {
        var samples = frames([(5, true)])
        samples[20] = HeadPoseSample(t: samples[20].t, yaw: nil, pitch: nil)   // Vision missed one frame
        samples[21].yaw = 40
        let m = try XCTUnwrap(CameraMeter.measure(samples, end: 5))
        XCTAssertEqual(m.faced_camera_pct, 100)
        XCTAssertEqual(m.looked_away_count, 0)
    }

    func testALookAwayThatRunsToTheEndLastsUntilRelease() throws {
        let samples = frames([(2, true), (1.5, false)])
        XCTAssertEqual(CameraMeter.measure(samples, end: 4.0)?.longest_look_away_ms, 2000, "until the key came up")
        XCTAssertEqual(CameraMeter.measure(samples)?.longest_look_away_ms, 1500, "or one frame past the last one")
    }

    func testLeavingTheFrameCountsAsAway() throws {
        var samples = frames([(2, true), (3, true), (2, true)])
        for i in 20..<50 { samples[i] = HeadPoseSample(t: samples[i].t, yaw: nil, pitch: nil) }
        let m = try XCTUnwrap(CameraMeter.measure(samples, end: 7))
        XCTAssertEqual(m.looked_away_count, 1)
        XCTAssertEqual(m.longest_look_away_ms, 3000)
        XCTAssertEqual(m.faced_camera_pct, 57)
        XCTAssertEqual(CameraMeter.measure(frames([(2, false)]))?.lookedAwayLine, "Looked away once")
    }

    func testTooFewFramesIsNoMeasurementAndOrderDoesNotMatter() throws {
        XCTAssertNil(CameraMeter.measure(frames([(0.4, true)])), "4 frames")
        XCTAssertNotNil(CameraMeter.measure(frames([(0.5, true)])), "5 frames")
        let samples = frames([(2, true), (2, false), (2, true)])
        XCTAssertEqual(CameraMeter.measure(samples.reversed(), end: 6), CameraMeter.measure(samples, end: 6))
    }

    func testSmoothingIsAFiveFrameMajority() {
        XCTAssertEqual(CameraMeter.smoothed([true, true, false, true, true]), [true, true, true, true, true])
        XCTAssertEqual(CameraMeter.smoothed([true, false, false, true, true]), [false, false, true, true, true])
        XCTAssertEqual(CameraMeter.smoothed([false, false, false, true, true, true, true]), [false, false, false, true, true, true, true], "a real change keeps its place")
        XCTAssertEqual(CameraMeter.smoothed([true, true, true, false, false, true, true, true]), [true, true, true, true, true, true, true, true], "two frames is a flicker")
        XCTAssertEqual(CameraMeter.smoothed([true, false]), [true, false], "a tie keeps each frame's own label")
        XCTAssertEqual(CameraMeter.smoothed([]), [])
    }

    func testHeaderIsSortedCompactJSONAndValuesAreClamped() throws {
        let m = CameraMetrics(faced_camera_pct: 62, looked_away_count: 3, longest_look_away_ms: 4100, frames: 148)
        XCTAssertEqual(m.headerValue, #"{"faced_camera_pct":62,"frames":148,"longest_look_away_ms":4100,"looked_away_count":3}"#)
        let wild = CameraMetrics(faced_camera_pct: 140, looked_away_count: 5000, longest_look_away_ms: 900_000, frames: 99_999)
        XCTAssertEqual(wild, CameraMetrics(faced_camera_pct: 100, looked_away_count: 1200, longest_look_away_ms: 120_000, frames: 1200))
        XCTAssertEqual(CameraMetrics(faced_camera_pct: -1, looked_away_count: 3, longest_look_away_ms: -5, frames: 0),
                       CameraMetrics(faced_camera_pct: 0, looked_away_count: 1, longest_look_away_ms: 0, frames: 1))
        XCTAssertLessThan(m.headerValue.utf8.count, 512)
        XCTAssertEqual(try JSONDecoder().decode(CameraMetrics.self, from: Data(m.headerValue.utf8)), m)
    }

    func testNoLabelUsesWordsTheProductDoesNotUse() {
        let lines = [0, 1, 3].flatMap { n -> [String] in
            let m = CameraMetrics(faced_camera_pct: 62, looked_away_count: n, longest_look_away_ms: 2000, frames: 100)
            return [m.facedLine, m.lookedAwayLine, m.longestLine ?? ""]
        }
        for line in lines {
            for banned in ["eye contact", "confident", "nervous", "body language", "engag", "emotion", "mood", "energy"] {
                XCTAssertFalse(line.lowercased().contains(banned), "\(line) says \(banned)")
            }
        }
    }

    func testLiveFacingFlipsOnlyAfterTwoFramesAgree() {
        var live = LiveFacing()
        XCTAssertNil(live.facing)
        XCTAssertTrue(live.push(HeadPoseSample(t: 0, yaw: 0, pitch: 0)))
        XCTAssertEqual(live.facing, true)
        XCTAssertFalse(live.push(HeadPoseSample(t: 0.1, yaw: 40, pitch: 0)), "one frame away is not enough")
        XCTAssertFalse(live.push(HeadPoseSample(t: 0.2, yaw: 0, pitch: 0)), "and a facing frame resets it")
        XCTAssertFalse(live.push(HeadPoseSample(t: 0.3, yaw: nil, pitch: nil)))
        XCTAssertTrue(live.push(HeadPoseSample(t: 0.4, yaw: 0, pitch: -30)))
        XCTAssertEqual(live.facing, false)
        XCTAssertFalse(live.push(HeadPoseSample(t: 0.5, yaw: 0, pitch: -30)))
    }
}

final class CameraEvalTests: XCTestCase {
    func testSyntheticScenariosMatchTheirNoiseFreeAnswer() throws {
        for scenario in CameraScenario.standardSet {
            let expected = try XCTUnwrap(scenario.expected())
            for seed in UInt64(1)...5 {
                let m = try XCTUnwrap(CameraMeter.measure(scenario.samples(seed: seed), end: scenario.duration), scenario.name)
                XCTAssertEqual(m.looked_away_count, expected.looked_away_count, "\(scenario.name), seed \(seed)")
                XCTAssertLessThanOrEqual(abs(m.faced_camera_pct - expected.faced_camera_pct), 10, "\(scenario.name), seed \(seed)")
            }
        }
        XCTAssertEqual(CameraScenario.standardSet[1].expected(), CameraMetrics(faced_camera_pct: 75, looked_away_count: 4, longest_look_away_ms: 2000, frames: 320))
    }

    func testSeededNoiseRepeats() {
        let a = CameraScenario.standardSet[2].samples(seed: 7), b = CameraScenario.standardSet[2].samples(seed: 7)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, CameraScenario.standardSet[2].samples(seed: 8))
    }

    func testHandLabelScoreAndTheFifteenPointRule() {
        // 10 s clip, 10 frames a second: away from 3 s to 5 s.
        let samples = (0..<100).map { i -> HeadPoseSample in
            let t = Double(i) / 10
            return HeadPoseSample(t: t, yaw: 0, pitch: (3..<5).contains(t) ? -35 : 0)
        }
        let agreeing = HandLabels(clip: "fixture", seconds: (0..<10).map { !(3..<5).contains($0) })
        let score = CameraEval.score(samples: samples, labels: agreeing)
        XCTAssertEqual(score.seconds, 10)
        XCTAssertEqual(score.agreement_pct, 100)
        XCTAssertEqual(score.hand_faced_pct, 80)
        XCTAssertEqual(score.meter_faced_pct, 80)
        XCTAssertTrue(score.passes)

        // A person who saw a longer look-away (2 s to 6 s): 60% by hand, 80% by the meter, 20 points off.
        let longer = HandLabels(clip: "fixture", seconds: (0..<10).map { !(2..<6).contains($0) })
        let off = CameraEval.score(samples: samples, labels: longer)
        XCTAssertEqual(off.difference_points, 20)
        XCTAssertFalse(off.passes)

        // Unlabelled seconds and seconds with no frames are skipped.
        let partial = HandLabels(clip: "fixture", seconds: [true, nil, true] + Array(repeating: nil, count: 20) + [true])
        XCTAssertEqual(CameraEval.score(samples: samples, labels: partial).seconds, 2)
        XCTAssertFalse(CameraEval.score(samples: [], labels: agreeing).passes, "no frames is not a pass")
    }

    func testSweepPutsTheBestConeFirst() {
        // The person's "away" is a 25° turn, which the standard 20° cone already catches; a 30° cone would not.
        let samples = (0..<100).map { i in HeadPoseSample(t: Double(i) / 10, yaw: i >= 50 ? 25 : 0, pitch: 0) }
        let labels = HandLabels(clip: "turn", seconds: (0..<10).map { $0 < 5 })
        let ranked = CameraEval.sweep(samples: samples, labels: labels)
        XCTAssertEqual(ranked.first?.agreement_pct, 100)
        XCTAssertLessThan(ranked.first!.max_yaw, 25)
        XCTAssertEqual(ranked.last?.agreement_pct, 50)
    }
}

final class CameraUploadTests: XCTestCase {
    private func api() -> CoachAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SequenceProtocol.self]
        return CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "local-test-token", session: URLSession(configuration: configuration))
    }

    override func setUp() { SequenceProtocol.requests = []; SequenceProtocol.bodies = []; SequenceProtocol.answers = [] }

    func testTheHoldSendsItsCameraNumbersAsOneHeader() async throws {
        let withCamera = voiceReceiptJSON.replacingOccurrences(of: #""onset_ms_approx":1200}"#,
            with: #""onset_ms_approx":1200,"camera":{"faced_camera_pct":62,"looked_away_count":3,"longest_look_away_ms":4100,"frames":148,"method":"vision-face-pose-v1"}}"#)
        SequenceProtocol.answers = [.status(200, withCamera), .status(200, voiceReceiptJSON)]
        var round = VoiceRoundRequest(wav: WAV.encode([1, 2]), idempotencyKey: "voice-cam-1")
        round.camera = CameraMetrics(faced_camera_pct: 62, looked_away_count: 3, longest_look_away_ms: 4100, frames: 148)
        let receipt = try await api().postVoiceRound(round)
        XCTAssertEqual(SequenceProtocol.requests.first?.value(forHTTPHeaderField: "X-Camera-Metrics"),
                       #"{"faced_camera_pct":62,"frames":148,"longest_look_away_ms":4100,"looked_away_count":3}"#)
        XCTAssertEqual(receipt.metrics?.camera, CameraMetrics(faced_camera_pct: 62, looked_away_count: 3, longest_look_away_ms: 4100, frames: 148))

        // Camera off: no header, and a receipt without camera numbers decodes as before.
        let plain = try await api().postVoiceRound(VoiceRoundRequest(wav: WAV.encode([1, 2]), idempotencyKey: "voice-cam-2"))
        XCTAssertNil(SequenceProtocol.requests.last?.value(forHTTPHeaderField: "X-Camera-Metrics"))
        XCTAssertNil(plain.metrics?.camera)
    }
}
