// Makes the hands check's clip from a movie on this Mac, with the app's own writer (ReplayClipWriter): one frame
// every 0.1 s, the camera's shape inside 640×360, H.264, no audio, at most 150 frames. Nothing is sent.
//   swift run -c release replay-clip --video <in.mov> --out <clip.mp4> [--start <seconds>]
@preconcurrency import AVFoundation
import Foundation
import ScreenContextCore

func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
guard let input = argument("--video"), let output = argument("--out") else {
    FileHandle.standardError.write(Data("usage: replay-clip --video <in.mov> --out <clip.mp4> [--start <seconds>]\n".utf8))
    exit(2)
}
let start = Double(argument("--start") ?? "0") ?? 0

let asset = AVURLAsset(url: URL(fileURLWithPath: input))
guard let track = try await asset.loadTracks(withMediaType: .video).first else { print("no video track"); exit(1) }
let reader = try AVAssetReader(asset: asset)
let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(frames)
guard reader.startReading() else { print("cannot read \(input)"); exit(1) }

let writer = ReplayClipWriter(url: URL(fileURLWithPath: output))
writer.beginSegment()
var next = start
while !writer.isFull, let sample = frames.copyNextSampleBuffer() {
    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    guard t + 0.0005 >= next, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
    next += Double(1) / Double(ReplayClip.fps)
    // Like the camera, the encoder may not be ready at once; offline, wait for it instead of dropping the frame.
    var taken = false
    for _ in 0..<400 where !taken { taken = writer.append(pixels); if !taken { try await Task.sleep(for: .milliseconds(5)) } }
}
reader.cancelReading()
let clip = try await writer.finish()
print(String(format: "%@: %d frames (%.1f s), %d bytes", output, clip.frames, Double(clip.frames) / Double(ReplayClip.fps), clip.bytes))
