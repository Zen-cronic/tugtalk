import Foundation

// "Faced the camera": which way the head points, read on this Mac from Apple Vision's face angles while
// ⌃⌥T is held. It is head direction, not gaze: the eyes can look away while the head stays still.
// No frame is kept, logged or sent. Only the four numbers in `CameraMetrics` leave the Mac.

/// One analysed camera frame: Apple Vision's head angles in degrees, or no face found.
public struct HeadPoseSample: Sendable, Equatable, Codable {
    /// Seconds since the hold started.
    public var t: Double
    /// Head turn left or right. Nil when no face was found in the frame.
    public var yaw: Double?
    /// Head tilt up or down. Nil when no face was found, or Vision gave no pitch.
    public var pitch: Double?

    public init(t: Double, yaw: Double?, pitch: Double?) { self.t = t; self.yaw = yaw; self.pitch = pitch }
}

/// When a frame counts as "faced the camera": a face was found, and its head turn and tilt are both inside the
/// cone. The cone is wide enough for small head movements while talking to the lens, and narrow enough that
/// turning to a second screen or tilting down to notes falls outside. See docs/camera.md.
public struct FacingRule: Sendable, Equatable {
    /// Largest head turn, left or right, in degrees.
    public var maxYaw: Double
    /// Largest head tilt, up or down, in degrees.
    public var maxPitch: Double

    public init(maxYaw: Double = 20, maxPitch: Double = 15) { self.maxYaw = maxYaw; self.maxPitch = maxPitch }

    public static let standard = FacingRule()

    /// No face, or no angle for it, counts as not facing: the person turned fully away or left the frame.
    public func faces(_ s: HeadPoseSample) -> Bool {
        guard let yaw = s.yaw, let pitch = s.pitch, yaw.isFinite, pitch.isFinite else { return false }
        return abs(yaw) <= maxYaw && abs(pitch) <= maxPitch
    }
}

/// The numbers one answer sends, as `X-Camera-Metrics`, and the record keeps as `metrics.camera`.
public struct CameraMetrics: Codable, Sendable, Equatable {
    /// Share of analysed frames in which the head faced the camera (after smoothing), 0 to 100.
    public let faced_camera_pct: Int
    /// Look-aways of at least `CameraMeter.minLookAway`.
    public let looked_away_count: Int
    /// The longest of those look-aways, in milliseconds; 0 when there were none.
    public let longest_look_away_ms: Int
    /// Frames analysed.
    public let frames: Int

    // The server refuses anything outside these bounds (src/camera-metrics.mjs uses the same numbers).
    public static let maxFrames = 1200
    public static let maxLookAwayMs = 120_000

    public init(faced_camera_pct: Int, looked_away_count: Int, longest_look_away_ms: Int, frames: Int) {
        let frames = min(max(frames, 1), Self.maxFrames)
        self.frames = frames
        self.faced_camera_pct = min(max(faced_camera_pct, 0), 100)
        self.looked_away_count = min(max(looked_away_count, 0), frames)
        self.longest_look_away_ms = min(max(longest_look_away_ms, 0), Self.maxLookAwayMs)
    }

    /// The header value: compact JSON with sorted keys, so a retry sends the same bytes.
    public var headerValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// "Faced the camera 62% of your answer".
    public var facedLine: String { "Faced the camera \(faced_camera_pct)% of your answer" }

    /// "Looked away 3 times", "Looked away once", "Didn't look away".
    public var lookedAwayLine: String {
        switch looked_away_count {
        case 0: "Didn't look away"
        case 1: "Looked away once"
        default: "Looked away \(looked_away_count) times"
        }
    }

    /// "longest 4.1 s", only when there was a look-away.
    public var longestLine: String? {
        looked_away_count > 0 ? String(format: "longest %.1f\u{00A0}s", Double(longest_look_away_ms) / 1000) : nil
    }
}

public enum CameraMeter {
    /// About 10 frames a second are analysed; the rest are dropped before Vision sees them.
    public static let frameInterval: Double = 0.1
    /// A look-away is counted once the head has been away this long. Shorter glances still lower the percentage.
    public static let minLookAway: Double = 1.0
    /// Each frame's label for counting is the majority of this many frames around it (half a second), so a
    /// flicker of one or two frames, from noise near the edge of the cone or a missed face, changes nothing.
    public static let smoothingFrames = 5
    /// Fewer analysed frames than this (about half a second) is no measurement, and nothing is sent.
    public static let minFrames = 5

    /// The answer's numbers, or nil with too few frames. `end` is when the hold ended, in the samples' clock;
    /// without it a look-away that runs to the end stops one frame interval after the last frame.
    public static func measure(_ samples: [HeadPoseSample], rule: FacingRule = .standard, end: Double? = nil) -> CameraMetrics? {
        let frames = samples.sorted { $0.t < $1.t }
        guard frames.count >= minFrames else { return nil }
        let labels = frames.map(rule.faces)
        // The percentage uses the same smoothed labels as the count, so a one-frame flicker moves neither.
        let facing = smoothed(labels).filter { $0 }.count
        let pct = Int((100 * Double(facing) / Double(frames.count)).rounded())
        let away = lookAways(frames.map(\.t), labels, end: max(end ?? 0, frames.last!.t + frameInterval))
        return CameraMetrics(faced_camera_pct: pct, looked_away_count: away.count,
                             longest_look_away_ms: Int(((away.max() ?? 0) * 1000).rounded()), frames: frames.count)
    }

    /// The durations, in seconds, of every look-away of at least `minLookAway`, after smoothing the labels.
    public static func lookAways(_ times: [Double], _ facing: [Bool], end: Double) -> [Double] {
        let labels = smoothed(facing)
        var runs: [(facing: Bool, start: Double, end: Double)] = []
        for (i, f) in labels.enumerated() {
            let stop = i + 1 < times.count ? times[i + 1] : end
            if let last = runs.last, last.facing == f { runs[runs.count - 1].end = stop } else { runs.append((f, times[i], stop)) }
        }
        return runs.filter { !$0.facing && $0.end - $0.start >= minLookAway - 1e-9 }.map { $0.end - $0.start }
    }

    /// The majority of the `smoothingFrames` frames centred on each one (fewer at the ends; a tie keeps the frame's own label).
    public static func smoothed(_ facing: [Bool]) -> [Bool] {
        let half = smoothingFrames / 2
        return facing.indices.map { i in
            let window = facing[max(0, i - half)...min(facing.count - 1, i + half)]
            let yes = window.filter { $0 }.count, no = window.count - yes
            return yes == no ? facing[i] : yes > no
        }
    }
}

/// The live "facing" bit for Tug's eyes and the dot under the camera. It flips only after two frames in a
/// row disagree with it (about 0.2 s), so a single noisy frame does not make Tug glance away.
public struct LiveFacing: Sendable, Equatable {
    public private(set) var facing: Bool?
    private var pending = 0
    private let rule: FacingRule
    public static let framesToFlip = 2

    public init(rule: FacingRule = .standard) { self.rule = rule }

    /// Returns true when `facing` changed.
    public mutating func push(_ sample: HeadPoseSample) -> Bool {
        let now = rule.faces(sample)
        guard let current = facing else { facing = now; return true }
        if now == current { pending = 0; return false }
        pending += 1
        guard pending >= Self.framesToFlip else { return false }
        facing = now; pending = 0
        return true
    }
}
