import Foundation

// Offline checks of the "faced the camera" meter: synthetic head-angle sequences with a known answer, and a
// scorer for a clip a person labelled by hand, second by second. `swift run camera-eval` runs both.

/// A person's labels for one clip: for each whole second, did the head face the camera?
public struct HandLabels: Codable, Sendable, Equatable {
    public var clip: String
    /// Index = second of the clip. Nil = not labelled (skipped).
    public var seconds: [Bool?]

    public init(clip: String, seconds: [Bool?]) { self.clip = clip; self.seconds = seconds }
}

/// How the meter compares with the hand labels on the same clip.
public struct HandLabelScore: Codable, Sendable, Equatable {
    /// Seconds with both a hand label and at least one analysed frame.
    public let seconds: Int
    /// Share of those seconds where the meter's majority label matches the hand label, 0 to 100.
    public let agreement_pct: Double
    /// Faced the camera, by hand: share of labelled seconds.
    public let hand_faced_pct: Double
    /// Faced the camera, by the meter: share of frames in the labelled seconds.
    public let meter_faced_pct: Double
    /// meter − hand, in percentage points.
    public let difference_points: Double
    /// The pass rule: the meter may be off from the hand labels by at most this many points.
    public let max_difference_points: Double
    public let passes: Bool
    public let max_yaw: Double
    public let max_pitch: Double
}

public enum CameraEval {
    /// The pass rule: the meter may differ from a person's hand labels by at most 15 points.
    public static let maxDifferencePoints = 15.0

    public static func score(samples: [HeadPoseSample], labels: HandLabels, rule: FacingRule = .standard) -> HandLabelScore {
        var agree = 0, counted = 0, handFaced = 0, meterFrames = 0, meterFaced = 0
        // The meter's own labels: the rule, then the same smoothing the shipped numbers use.
        let frames = samples.sorted { $0.t < $1.t }
        let meterLabels = zip(frames, CameraMeter.smoothed(frames.map(rule.faces))).map { (t: $0.t, faced: $1) }
        for (second, label) in labels.seconds.enumerated() {
            guard let label else { continue }
            let inSecond = meterLabels.filter { $0.t >= Double(second) && $0.t < Double(second + 1) }
            guard !inSecond.isEmpty else { continue }
            let faced = inSecond.filter(\.faced).count
            let majority = Double(faced) >= Double(inSecond.count) / 2
            counted += 1
            if majority == label { agree += 1 }
            if label { handFaced += 1 }
            meterFrames += inSecond.count
            meterFaced += faced
        }
        let pct = { (a: Int, b: Int) in b == 0 ? 0 : (1000 * Double(a) / Double(b)).rounded() / 10 }
        let hand = pct(handFaced, counted), meter = pct(meterFaced, meterFrames)
        let diff = ((meter - hand) * 10).rounded() / 10
        return HandLabelScore(seconds: counted, agreement_pct: pct(agree, counted), hand_faced_pct: hand, meter_faced_pct: meter,
                              difference_points: diff, max_difference_points: maxDifferencePoints,
                              passes: counted > 0 && abs(diff) <= maxDifferencePoints, max_yaw: rule.maxYaw, max_pitch: rule.maxPitch)
    }

    /// Tries a grid of cones on the same labelled clip, best agreement first. For tuning the rule at the
    /// accuracy check, not at run time.
    public static func sweep(samples: [HeadPoseSample], labels: HandLabels,
                             yaws: [Double] = stride(from: 10, through: 35, by: 5).map { $0 },
                             pitches: [Double] = stride(from: 8, through: 30, by: 2).map { $0 }) -> [HandLabelScore] {
        yaws.flatMap { y in pitches.map { p in score(samples: samples, labels: labels, rule: FacingRule(maxYaw: y, maxPitch: p)) } }
            .sorted { ($0.agreement_pct, -abs($0.difference_points)) > ($1.agreement_pct, -abs($1.difference_points)) }
    }
}

/// A seeded generator, so every synthetic run gives the same numbers.
public struct SeededRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
    /// Normal noise with this standard deviation.
    public mutating func gaussian(_ sd: Double) -> Double {
        let u = max(next(), 1e-12), v = next()
        return sd * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// A synthetic answer: what the head did, segment by segment, at 10 frames a second, plus measurement noise.
public struct CameraScenario: Sendable {
    public struct Segment: Sendable {
        public var seconds: Double
        public var yaw: Double
        public var pitch: Double
        /// No face in these frames (left the frame).
        public var noFace = false
        public init(_ seconds: Double, yaw: Double = 0, pitch: Double = 0, noFace: Bool = false) {
            self.seconds = seconds; self.yaw = yaw; self.pitch = pitch; self.noFace = noFace
        }
    }

    public let name: String
    public let segments: [Segment]
    /// Degrees of noise added to each angle, each frame.
    public let noise: Double
    /// Share of frames Vision misses at random, even with a face there.
    public let dropRate: Double

    public init(name: String, segments: [Segment], noise: Double = 3, dropRate: Double = 0.02) {
        self.name = name; self.segments = segments; self.noise = noise; self.dropRate = dropRate
    }

    public var duration: Double { segments.reduce(0) { $0 + $1.seconds } }

    /// The noisy frames the meter sees.
    public func samples(seed: UInt64) -> [HeadPoseSample] {
        var rng = SeededRandom(seed: seed)
        return truth().map { frame in
            if frame.segment.noFace || rng.next() < dropRate { return HeadPoseSample(t: frame.t, yaw: nil, pitch: nil) }
            return HeadPoseSample(t: frame.t, yaw: frame.segment.yaw + rng.gaussian(noise), pitch: frame.segment.pitch + rng.gaussian(noise))
        }
    }

    /// The answer the meter should give: the noise-free head angles through the same rule.
    public func expected(rule: FacingRule = .standard) -> CameraMetrics? {
        CameraMeter.measure(truth().map { f in f.segment.noFace ? HeadPoseSample(t: f.t, yaw: nil, pitch: nil) : HeadPoseSample(t: f.t, yaw: f.segment.yaw, pitch: f.segment.pitch) },
                            rule: rule, end: duration)
    }

    private func truth() -> [(t: Double, segment: Segment)] {
        var frames: [(Double, Segment)] = []
        var start = 0.0
        for segment in segments {
            let n = Int((segment.seconds / CameraMeter.frameInterval).rounded())
            for i in 0..<n { frames.append((start + Double(i) * CameraMeter.frameInterval, segment)) }
            start += segment.seconds
        }
        return frames
    }

    /// Everyday answers: talking to the lens, notes below the screen, a second screen to the side, quick glances,
    /// a head held near the edge of the cone, and leaving the frame.
    public static let standardSet: [CameraScenario] = [
        CameraScenario(name: "faces the camera throughout", segments: [.init(30, yaw: 2, pitch: -3)]),
        CameraScenario(name: "reads notes below the screen every 8 s", segments: Array(repeating: [.init(6, yaw: 1, pitch: -2), .init(2, yaw: 0, pitch: -32)], count: 4).flatMap { $0 }),
        CameraScenario(name: "turns to a second screen twice", segments: [.init(5, yaw: 3), .init(4, yaw: 38, pitch: -4), .init(8, yaw: -2), .init(3, yaw: 40), .init(5, yaw: 0)]),
        CameraScenario(name: "quick glances under a second", segments: Array(repeating: [.init(3, yaw: 0, pitch: -2), .init(0.5, yaw: 4, pitch: -30)], count: 6).flatMap { $0 }),
        CameraScenario(name: "holds the head near the cone's edge", segments: [.init(20, yaw: 16, pitch: -10)], noise: 3),
        CameraScenario(name: "leaves the frame for 3 s", segments: [.init(6), .init(3, noFace: true), .init(6)]),
        CameraScenario(name: "looks down at a phone most of the answer", segments: [.init(2), .init(12, yaw: 5, pitch: -40), .init(2)]),
        CameraScenario(name: "noisy detection while facing", segments: [.init(25, yaw: 0, pitch: -4)], noise: 6, dropRate: 0.08),
    ]
}
