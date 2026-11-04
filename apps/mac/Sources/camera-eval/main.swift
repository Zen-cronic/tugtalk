// camera-eval: offline checks of the "faced the camera" meter. No camera, no network.
//
//   camera-eval synthetic [--out ../../eval/camera-synthetic.json]
//       Runs the meter on synthetic head-angle sequences with a known answer (noise and missed frames added).
//   camera-eval poses --video clip.mov --out poses.json
//       Reads a recorded clip at 10 frames a second with the same Vision code the app uses, and writes only
//       the head angles per frame (no pictures). Also prints how long Vision took per frame.
//   camera-eval score --poses poses.json --labels labels.json [--sweep] [--max-yaw 20 --max-pitch 15]
//       Compares the meter with hand labels from scripts/camera-label.mjs. Exits 1 when the meter is off
//       by more than 15 points. --sweep also lists the cones that agree best with the labels.
import AVFoundation
import Foundation
import ScreenContextCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("Usage: camera-eval synthetic | poses --video f.mov --out poses.json | score --poses p.json --labels l.json") }
arguments.removeFirst()
var options: [String: String] = [:]
var flags: Set<String> = []
var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--sweep": flags.insert(argument)
    case "--out", "--video", "--poses", "--labels", "--max-yaw", "--max-pitch":
        guard let value = iterator.next() else { fail("Missing value for \(argument)") }
        options[argument] = value
    default: fail("Unknown argument \(argument). See the header of Sources/camera-eval/main.swift.")
    }
}
let rule = FacingRule(maxYaw: options["--max-yaw"].flatMap(Double.init) ?? FacingRule.standard.maxYaw,
                      maxPitch: options["--max-pitch"].flatMap(Double.init) ?? FacingRule.standard.maxPitch)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

func write<T: Encodable>(_ value: T, to path: String?) throws {
    let data = try encoder.encode(value)
    if let path { try data.write(to: URL(fileURLWithPath: path)) } else { print(String(decoding: data, as: UTF8.self)) }
}

struct SyntheticRow: Codable {
    let scenario: String
    let seconds: Double
    let expected: CameraMetrics?
    /// The meter on noisy frames, one entry per seed.
    let measured: [CameraMetrics?]
    let worst_pct_error: Int
    let count_matches: Int
}

struct SyntheticReport: Codable {
    let method: String
    let rule: [String: Double]
    let seeds: Int
    let note: String
    let scenarios: [SyntheticRow]
    let worst_pct_error: Int
    let count_match_rate: Double
}

switch command {
case "synthetic":
    let seeds: [UInt64] = Array(1...20)
    var rows: [SyntheticRow] = []
    for scenario in CameraScenario.standardSet {
        let expected = scenario.expected(rule: rule)
        let measured = seeds.map { CameraMeter.measure(scenario.samples(seed: $0), rule: rule, end: scenario.duration) }
        let errors = measured.map { m in abs((m?.faced_camera_pct ?? 0) - (expected?.faced_camera_pct ?? 0)) }
        let matches = measured.filter { $0?.looked_away_count == expected?.looked_away_count }.count
        rows.append(SyntheticRow(scenario: scenario.name, seconds: scenario.duration, expected: expected, measured: measured,
                                 worst_pct_error: errors.max() ?? 0, count_matches: matches))
        let name = scenario.name.padding(toLength: 42, withPad: " ", startingAt: 0)
        print(name + String(format: " expected %3d%%, %d away, worst error %2d pts, count right %2d/%d",
                            expected?.faced_camera_pct ?? -1, expected?.looked_away_count ?? -1, errors.max() ?? 0, matches, seeds.count))
    }
    let report = SyntheticReport(method: "vision-face-pose-v1 meter on synthetic head angles (camera-eval synthetic)",
                                 rule: ["max_yaw_deg": rule.maxYaw, "max_pitch_deg": rule.maxPitch], seeds: seeds.count,
                                 note: "Expected = the same rule on the noise-free angles. This checks the counting and its robustness to noise and missed frames, not Vision's accuracy on a real face.",
                                 scenarios: rows, worst_pct_error: rows.map(\.worst_pct_error).max() ?? 0,
                                 count_match_rate: Double(rows.map(\.count_matches).reduce(0, +)) / Double(rows.count * seeds.count))
    try write(report, to: options["--out"])
    if options["--out"] != nil { print("Wrote \(options["--out"]!)") }

case "poses":
    guard let video = options["--video"] else { fail("poses needs --video clip.mov") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: video))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("No video track in \(video)") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { fail("Could not read \(video): \(reader.error?.localizedDescription ?? "unknown error")") }
    var samples: [HeadPoseSample] = []
    var next = 0.0, visionSeconds = 0.0
    while let buffer = output.copyNextSampleBuffer() {
        let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        guard t >= next - 0.001, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
        next = t + CameraMeter.frameInterval
        let started = Date()
        let angles = HeadPoseReader.angles(in: pixels)
        visionSeconds += Date().timeIntervalSince(started)
        samples.append(HeadPoseSample(t: t, yaw: angles.yaw, pitch: angles.pitch))
    }
    try write(samples, to: options["--out"])
    let found = samples.filter { $0.yaw != nil }.count
    FileHandle.standardError.write(Data(String(format: "%d frames, face found in %d; Vision %.1f ms per frame on average\n",
                                               samples.count, found, samples.isEmpty ? 0 : 1000 * visionSeconds / Double(samples.count)).utf8))
    if let m = CameraMeter.measure(samples, rule: rule) {
        FileHandle.standardError.write(Data("Meter: \(m.facedLine), \(m.lookedAwayLine)\(m.longestLine.map { ", \($0)" } ?? "")\n".utf8))
    }

case "score":
    guard let posesPath = options["--poses"], let labelsPath = options["--labels"] else { fail("score needs --poses and --labels") }
    let decoder = JSONDecoder()
    let samples = try decoder.decode([HeadPoseSample].self, from: Data(contentsOf: URL(fileURLWithPath: posesPath)))
    let labels = try decoder.decode(HandLabels.self, from: Data(contentsOf: URL(fileURLWithPath: labelsPath)))
    let result = CameraEval.score(samples: samples, labels: labels, rule: rule)
    try write(result, to: options["--out"])
    if flags.contains("--sweep") {
        print("Best cones on this clip (agreement, meter − hand):")
        for s in CameraEval.sweep(samples: samples, labels: labels).prefix(8) {
            print(String(format: "  yaw ≤ %2.0f°, pitch ≤ %2.0f°: %5.1f%% agree, %+5.1f pts", s.max_yaw, s.max_pitch, s.agreement_pct, s.difference_points))
        }
    }
    exit(result.passes ? 0 : 1)

default:
    fail("Unknown command \(command). Use synthetic, poses or score.")
}
