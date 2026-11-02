import Foundation

/// Tug's idle breath, kept free of AppKit so it is unit-tested. Units are Tug's 64-unit drawing, y down.
///
/// One loop of `period` seconds: the body bobs and the slack string sways with it. Blinks come at uneven gaps
/// over a longer loop. The app hands both loops to Core Animation, which plays them on the render server, so the
/// app itself draws nothing while Tug rests.
public enum TugBreath {
    public static let period: Double = 3.6
    public static let bobAmplitude: Double = 0.9
    public static let swayAmplitude: Double = 0.8
    /// The string's still: the sway the Reduce Motion pose shows, so the loop starts from the still and ends on it.
    public static let stillSwayPhase: Double = 0.56

    /// Down is positive. Zero at the start of the loop, like the still.
    public static func bob(at t: Double) -> Double { bobAmplitude * sin(2 * .pi * t / period) }

    public static func sway(at t: Double) -> Double { swayAmplitude * sin(stillSwayPhase + 2 * .pi * t / period) }

    /// `count` evenly spaced moments over one loop, plus the loop's end, which matches its start.
    public static func moments(count: Int) -> [Double] {
        (0...count).map { period * Double($0) / Double(count) }
    }
}

/// How open Tug's eyes are in one frame of a blink.
public enum TugEye: Hashable, Sendable { case open, half, shut }

/// When Tug blinks: every few seconds at uneven gaps, now and then twice in a row. A loop of `loop` seconds;
/// the gap from the last blink round to the first is one of the drawn gaps, so the loop has no seam.
public struct BlinkSchedule: Equatable, Sendable {
    public let loop: Double
    /// Start of each blink, in seconds into the loop.
    public let starts: [Double]

    public static let gaps: ClosedRange<Double> = 2.6...6.2
    /// Half shut, shut, half shut, open: 0.14 s in all.
    public static let frames: [(eye: TugEye, at: Double)] = [(.half, 0), (.shut, 0.04), (.half, 0.10), (.open, 0.14)]
    public static let length = 0.14
    /// A second blink starts this long after the first one starts.
    public static let doubleGap = 0.3
    /// The first blink waits this long after Tug comes to rest.
    public static let lead = 1.0

    public init(loop: Double, starts: [Double]) {
        self.loop = loop
        self.starts = starts
    }

    /// `rounds` blink rounds; about one in five is a double blink.
    public static func random<G: RandomNumberGenerator>(rounds: Int = 7, using rng: inout G) -> BlinkSchedule {
        var starts: [Double] = [], at = lead, loop = 0.0
        for _ in 0..<max(1, rounds) {
            starts.append(at)
            if Double.random(in: 0..<1, using: &rng) < 0.2 { starts.append(at + doubleGap) }
            let gap = Double.random(in: gaps, using: &rng)
            at += gap
            loop += gap
        }
        return BlinkSchedule(loop: loop, starts: starts)
    }

    /// Discrete keyframes for the loop: `eyes[i]` holds from `keyTimes[i]` to `keyTimes[i + 1]`, as Core Animation's
    /// discrete mode expects (one more key time than values, from 0 to 1).
    public var keyframes: (keyTimes: [Double], eyes: [TugEye]) {
        var times: [Double] = [0], eyes: [TugEye] = [.open]
        for start in starts {
            for frame in Self.frames {
                let at = (start + frame.at) / loop
                guard let last = times.last, at > last else { continue }
                times.append(at)
                eyes.append(frame.eye)
            }
        }
        times.append(1)
        return (times, eyes)
    }
}
