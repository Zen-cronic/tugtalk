@preconcurrency import AVFoundation
import CoreVideo
import XCTest
@testable import ScreenContextCore

/// What `POST /v1/voice-rounds/{id}/replay` answers for the CC0 test clip (test/fixtures/sam), from src/replay.mjs.
let replayReceiptJSON = #"{"round_id":"vr9","receipt_id":"rc9","replayed":false,"record_version":2,"replay":{"method":"sam-3.1-boxes-v1","model":"sam-3.1","concepts":["hand","phone","paper"],"fps":10,"frames":100,"seconds":{"phone_in_hand":7,"paper_in_hand":0},"per_second":[{"frames":10,"phone_in_hand":10,"paper_in_hand":0,"in_hand":10},{"frames":10,"phone_in_hand":10,"paper_in_hand":0,"in_hand":10},{"frames":10,"phone_in_hand":10,"paper_in_hand":0,"in_hand":10},{"frames":10,"phone_in_hand":10,"paper_in_hand":0,"in_hand":10},{"frames":10,"phone_in_hand":0,"paper_in_hand":0,"in_hand":0},{"frames":10,"phone_in_hand":0,"paper_in_hand":0,"in_hand":0},{"frames":10,"phone_in_hand":0,"paper_in_hand":0,"in_hand":0},{"frames":10,"phone_in_hand":10,"paper_in_hand":0,"in_hand":10},{"frames":10,"phone_in_hand":10,"paper_in_hand":0,"in_hand":10},{"frames":10,"phone_in_hand":10,"paper_in_hand":0,"in_hand":10}],"segments":[{"answer":1,"start_frame":0,"end_frame":40,"phone_in_hand":4,"paper_in_hand":0},{"answer":2,"start_frame":40,"end_frame":100,"phone_in_hand":3,"paper_in_hand":0}],"sam_ms":{"hand":4700,"phone":4700,"paper":4700},"wall_ms":4900,"store":false,"clip_retained":false,"checked_at":"2026-11-02T21:00:00.000Z"}}"#

final class ReplayClipTests: XCTestCase {
    private func frame(_ width: Int, _ height: Int, shade: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(shade), CVPixelBufferGetBytesPerRow(pixels) * height)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// Like the camera: a frame the encoder is not ready for is dropped, so the test waits a little and offers it again.
    private func offer(_ writer: ReplayClipWriter, _ pixels: CVPixelBuffer) async -> Bool {
        for _ in 0..<200 {
            if writer.append(pixels) { return true }
            if writer.isFull { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func temp() -> URL { FileManager.default.temporaryDirectory.appending(path: "replay-test-\(UUID().uuidString).mp4") }

    func testSizeKeepsTheCameraShapeInside640By360() {
        XCTAssertTrue(ReplayClip.size(forWidth: 640, height: 480) == (480, 360), "a 4:3 camera keeps its bottom edge, where hands are")
        XCTAssertTrue(ReplayClip.size(forWidth: 1280, height: 720) == (640, 360))
        XCTAssertTrue(ReplayClip.size(forWidth: 1920, height: 1080) == (640, 360))
        XCTAssertTrue(ReplayClip.size(forWidth: 320, height: 240) == (320, 240), "never scaled up")
        XCTAssertTrue(ReplayClip.size(forWidth: 641, height: 481) == (478, 360), "even sides, never past 640×360")
    }

    func testWriterMakesOneSilentH264ClipAcrossHoldsAndStopsAt150Frames() async throws {
        let url = temp()
        let writer = ReplayClipWriter(url: url)
        writer.beginSegment()
        for i in 0..<60 { let ok = await offer(writer, frame(640, 480, shade: UInt8(i * 3))); XCTAssertTrue(ok) }
        writer.beginSegment()
        var taken = 0
        for i in 0..<120 where await offer(writer, frame(640, 480, shade: UInt8(200 - i))) { taken += 1 }
        XCTAssertEqual(taken, 90, "the clip stops at 150 frames")
        XCTAssertTrue(writer.isFull)
        let clip = try await writer.finish()
        defer { try? FileManager.default.removeItem(at: clip.url) }
        XCTAssertEqual(clip.frames, 150)
        XCTAssertEqual(clip.segments, [0..<60, 60..<150])
        XCTAssertEqual(ReplayClip.segmentsHeader(clip.segments), "0-60,60-150")
        XCTAssertLessThan(clip.bytes, ReplayClip.maxBytes)
        XCTAssertFalse(writer.append(frame(640, 480, shade: 1)), "a finished clip takes no more frames")

        let data = try Data(contentsOf: clip.url)
        XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp")
        let moov = try XCTUnwrap(data.range(of: Data("moov".utf8))), mdat = try XCTUnwrap(data.range(of: Data("mdat".utf8)))
        XCTAssertLessThan(moov.lowerBound, mdat.lowerBound, "faststart: the index comes before the frames")

        let asset = AVURLAsset(url: clip.url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 0, "no audio track")
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 480, height: 360))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 15, accuracy: 0.05, "150 frames at 10 a second; the gap between holds is not in the clip")
        let formats = try await video[0].load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video[0], outputSettings: nil)
        reader.add(output); reader.startReading()
        var samples = 0
        while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(samples, 150)
    }

    func testAWriterWithNoFramesLeavesNoFileAndCancelDeletesIt() async throws {
        let empty = ReplayClipWriter(url: temp())
        do { _ = try await empty.finish(); XCTFail("no frames, no clip") } catch { XCTAssertEqual(error as? ReplayClipError, .noFrames) }
        let url = temp()
        let writer = ReplayClipWriter(url: url)
        for _ in 0..<5 { _ = await offer(writer, frame(640, 480, shade: 9)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        writer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a round left without a wrap-up keeps no clip")
    }

    func testTheReceiptDecodesAndLabelsOnlyCountedObjects() throws {
        let receipt = try JSONDecoder().decode(ReplayReceipt.self, from: Data(replayReceiptJSON.utf8))
        XCTAssertEqual(receipt.replay.seconds, ReplaySeconds(phone_in_hand: 7, paper_in_hand: 0))
        XCTAssertEqual(receipt.replay.label, "phone in hand 7\u{00A0}s")
        XCTAssertEqual(receipt.replay.cells, [1, 1, 1, 1, 0, 0, 0, 1, 1, 1])
        let both = ReplayCounts(method: "m", fps: 10, frames: 30, seconds: ReplaySeconds(phone_in_hand: 2.8, paper_in_hand: 0.4),
                                per_second: [ReplaySecond(frames: 10, phone_in_hand: 5, paper_in_hand: 0, in_hand: 5)])
        XCTAssertEqual(both.label, "phone in hand 2.8\u{00A0}s · paper in hand 0.4\u{00A0}s")
        XCTAssertEqual(both.cells, [0.5])
        let none = ReplayCounts(method: "m", fps: 10, frames: 30, seconds: ReplaySeconds(phone_in_hand: 0, paper_in_hand: 0), per_second: [])
        XCTAssertEqual(none.label, "no phone or paper in hand")
        for word in ["confiden", "nerv", "posture", "eye", "focus", "distract"] {
            XCTAssertFalse(both.label.lowercased().contains(word)); XCTAssertFalse(none.label.lowercased().contains(word))
        }
    }

    func testSendReplayPostsTheClipWithItsSegmentsAndKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SequenceProtocol.self]
        let api = CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "local-test-token", session: URLSession(configuration: configuration))
        SequenceProtocol.requests = []; SequenceProtocol.bodies = []
        SequenceProtocol.answers = [.status(200, replayReceiptJSON)]
        let clip = Data([0, 0, 0, 24]) + Data("ftypisom".utf8)
        let receipt = try await api.sendReplay(roundID: "vr9", clip: clip, segments: [0..<40, 40..<100], idempotencyKey: "mac-replay-1")
        let request = try XCTUnwrap(SequenceProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/voice-rounds/vr9/replay"); XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "mac-replay-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Replay-Segments"), "0-40,40-100")
        XCTAssertEqual(SequenceProtocol.bodies.first, clip)
        XCTAssertEqual(receipt.round_id, "vr9")
    }
}
