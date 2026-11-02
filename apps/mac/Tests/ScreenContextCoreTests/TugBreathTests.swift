import Foundation
import XCTest
@testable import ScreenContextCore

/// SplitMix64, so a blink schedule is the same on every run.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class TugBreathTests: XCTestCase {
    func testTheLoopStartsAndEndsOnTheStill() {
        XCTAssertEqual(TugBreath.bob(at: 0), 0, accuracy: 1e-9, "the body starts where the still pose is")
        XCTAssertEqual(TugBreath.sway(at: 0), 0.8 * sin(1.6 * 0.35), accuracy: 1e-9, "the string starts where the still pose is")
        let moments = TugBreath.moments(count: 36)
        XCTAssertEqual(moments.count, 37)
        XCTAssertEqual(moments.last!, TugBreath.period, accuracy: 1e-9)
        XCTAssertEqual(TugBreath.bob(at: moments.last!), TugBreath.bob(at: 0), accuracy: 1e-9, "no jump where the loop repeats")
        XCTAssertEqual(TugBreath.sway(at: moments.last!), TugBreath.sway(at: 0), accuracy: 1e-9)
    }

    func testTheBreathStaysSmall() {
        for t in TugBreath.moments(count: 360) {
            XCTAssertLessThanOrEqual(abs(TugBreath.bob(at: t)), 0.9 + 1e-9)
            XCTAssertLessThanOrEqual(abs(TugBreath.sway(at: t)), 0.8 + 1e-9)
        }
    }

    func testBlinksComeEveryFewSecondsAtUnevenGaps() {
        var rng = SeededRNG(state: 7)
        let schedule = BlinkSchedule.random(rounds: 7, using: &rng)
        let rounds = schedule.starts.enumerated().filter { i, start in
            i == 0 || start - schedule.starts[i - 1] > BlinkSchedule.doubleGap + 1e-9
        }.map(\.element)
        XCTAssertEqual(rounds.count, 7)
        var gaps = zip(rounds.dropFirst(), rounds).map { $0 - $1 }
        gaps.append(schedule.loop - rounds.last! + rounds.first!)   // across the seam
        for gap in gaps { XCTAssertTrue(BlinkSchedule.gaps.contains(gap), "gap \(gap)") }
        XCTAssertGreaterThan(Set(gaps.map { ($0 * 10).rounded() }).count, 3, "the gaps vary")
        XCTAssertLessThan(schedule.starts.last! + BlinkSchedule.doubleGap + BlinkSchedule.length, schedule.loop, "the last blink ends inside the loop")
    }

    func testSomeBlinksAreDouble() {
        var rng = SeededRNG(state: 1)
        let doubles = (0..<40).map { _ in BlinkSchedule.random(rounds: 7, using: &rng) }
            .map { s in zip(s.starts.dropFirst(), s.starts).filter { abs($0 - $1 - BlinkSchedule.doubleGap) < 1e-9 }.count }
            .reduce(0, +)
        XCTAssertGreaterThan(doubles, 20)
        XCTAssertLessThan(doubles, 110, "about one round in five")
    }

    func testKeyframesSuitCoreAnimationsDiscreteMode() {
        var rng = SeededRNG(state: 42)
        let schedule = BlinkSchedule.random(using: &rng)
        let (times, eyes) = schedule.keyframes
        XCTAssertEqual(times.count, eyes.count + 1, "discrete mode wants one more key time than values")
        XCTAssertEqual(times.first, 0); XCTAssertEqual(times.last, 1)
        XCTAssertEqual(zip(times.dropFirst(), times).filter { $0 <= $1 }.count, 0, "key times rise")
        XCTAssertEqual(eyes.first, .open); XCTAssertEqual(eyes.last, .open, "the eyes are open at the seam")
        XCTAssertEqual(eyes.filter { $0 == .shut }.count, schedule.starts.count, "one shut frame per blink")
        // Each blink is shut for 0.06 s.
        for (i, eye) in eyes.enumerated() where eye == .shut {
            XCTAssertEqual((times[i + 1] - times[i]) * schedule.loop, 0.06, accuracy: 1e-9)
        }
    }

    func testAFixedScheduleBlinksWhereItSays() {
        let schedule = BlinkSchedule(loop: 10, starts: [1, 6])
        let (times, eyes) = schedule.keyframes
        XCTAssertEqual(eyes, [.open, .half, .shut, .half, .open, .half, .shut, .half, .open])
        XCTAssertEqual(times.map { ($0 * 1000).rounded() / 100 }, [0, 1, 1.04, 1.1, 1.14, 6, 6.04, 6.1, 6.14, 10])
    }
}
