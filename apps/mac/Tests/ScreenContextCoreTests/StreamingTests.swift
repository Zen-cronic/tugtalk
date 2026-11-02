import AudioToolbox
import Foundation
import XCTest
@testable import ScreenContextCore

/// A 1.2 s 440 Hz tone, MP3 at 24 kHz mono 32 kbps (made with ffmpeg's sine source; no voice).
private func tone() throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "mp3")))
}

private func chunks(_ data: Data, size: Int) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
}

final class AudioStreamParserTests: XCTestCase {
    func testPacketsAreTheSameWhateverTheChunkBoundaries() throws {
        let mp3 = try tone()
        func parse(_ parts: [Data]) -> (packets: Int, bytes: Int, rate: Double) {
            let parser = AudioStreamParser(contentType: "audio/mpeg")!
            var packets = 0, bytes = 0
            parser.onPackets = { packets += $0.descriptions.count; bytes += $0.data.count }
            for part in parts { XCTAssertTrue(parser.parse(part)) }
            return (packets, bytes, parser.format?.mSampleRate ?? 0)
        }
        let whole = parse([mp3])
        XCTAssertGreaterThanOrEqual(whole.packets, 48, "about 50 MP3 frames of 24 ms")
        XCTAssertEqual(whole.rate, 24_000)
        // Split anywhere a network or socket would split it. With small first chunks Core Audio may also pass on the
        // silent header frame as audio, so at most one frame more.
        for size in [64, 333, 1024, 2048] {
            let split = parse(chunks(mp3, size: size))
            XCTAssertTrue((whole.packets...whole.packets + 1).contains(split.packets), "chunks of \(size) bytes: \(split.packets)")
            XCTAssertLessThanOrEqual(abs(split.bytes - whole.bytes), 200)
        }
    }
}

/// A source the test feeds by hand.
private final class Feed: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init() { (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self) }
}

@MainActor
private final class Recorder {
    var log: [String] = []
    var events: SpeechEvents {
        SpeechEvents(started: { [weak self] provider in self?.log.append("started \(provider ?? "-")") },
                     finished: { [weak self] _ in self?.log.append("finished") },
                     failed: { [weak self] error in self?.log.append("failed \(error)") })
    }
}

@MainActor
final class StreamingSpeakerTests: XCTestCase {
    private let line = SpokenLine(text: "Why you?", language: .en, roundID: "round-1")

    private func wait(for condition: @escaping () -> Bool, seconds: Double = 4) async {
        let until = Date().addingTimeInterval(seconds)
        while !condition() && Date() < until { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testChunksPlayAsTheyArriveAndTheEndIsReportedOnce() async throws {
        let mp3 = try tone(), feed = Feed(), recorder = Recorder()
        let speaker = StreamingSpeaker(volume: { 0 }) { _ in SpeechStream(contentType: "audio/mpeg", provider: "wit", chunks: feed.stream) }
        var startedAfter: TimeInterval?
        speaker.onStarted = { after, _ in startedAfter = after }
        speaker.speak(line, events: recorder.events)
        let parts = chunks(mp3, size: 900)
        feed.continuation.yield(parts[0]); feed.continuation.yield(parts[1])
        await wait { recorder.log.contains("started wit") }
        XCTAssertEqual(recorder.log, ["started wit"], "sound starts on the first chunks, before the rest exists")
        XCTAssertLessThan(try XCTUnwrap(startedAfter), 1.0)
        for part in parts.dropFirst(2) { feed.continuation.yield(part) }
        feed.continuation.finish()
        await wait { recorder.log.count == 2 }
        XCTAssertEqual(recorder.log, ["started wit", "finished"])
    }

    func testNoSoundWithinTheFirstAudioWaitFailsSoTheRouterFallsBack() async {
        let feed = Feed(), recorder = Recorder()
        let speaker = StreamingSpeaker(firstAudio: .milliseconds(300), volume: { 0 }) { _ in SpeechStream(contentType: "audio/mpeg", provider: "wit", chunks: feed.stream) }
        speaker.speak(line, events: recorder.events)
        await wait { !recorder.log.isEmpty }
        XCTAssertEqual(recorder.log, ["failed \(SpeechFetchError.timedOut)"])
        // A source that fails before any audio fails at once.
        let broken = StreamingSpeaker(volume: { 0 }) { _ in throw CoachError.server(503, "speech_unconfigured", "No voice") }
        let other = Recorder()
        broken.speak(line, events: other.events)
        await wait { !other.log.isEmpty }
        XCTAssertEqual(other.log.count, 1); XCTAssertTrue(other.log[0].hasPrefix("failed"))
    }

    func testStopSilencesAtOnceAndNothingIsReportedAfter() async throws {
        let mp3 = try tone(), feed = Feed(), recorder = Recorder()
        let speaker = StreamingSpeaker(volume: { 0 }) { _ in SpeechStream(contentType: "audio/mpeg", provider: "wit", chunks: feed.stream) }
        speaker.speak(line, events: recorder.events)
        for part in chunks(mp3, size: 1200) { feed.continuation.yield(part) }
        await wait { recorder.log.contains("started wit") }
        speaker.stop()   // barge-in
        feed.continuation.finish()
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(recorder.log, ["started wit"], "no finished after a barge-in")
    }

    func testAStreamCutShortAfterSoundPlaysWhatArrived() async throws {
        let mp3 = try tone(), feed = Feed(), recorder = Recorder()
        let speaker = StreamingSpeaker(volume: { 0 }) { _ in SpeechStream(contentType: "audio/mpeg", provider: "wit", chunks: feed.stream) }
        speaker.speak(line, events: recorder.events)
        feed.continuation.yield(mp3.prefix(2600))
        await wait { recorder.log.contains("started wit") }
        feed.continuation.finish(throwing: CoachError.offline("cut"))
        await wait { recorder.log.count == 2 }
        XCTAssertEqual(recorder.log, ["started wit", "finished"])
    }
}

private final class FakeSocket: LiveSocket, @unchecked Sendable {
    var texts: [String] = [], data: [Data] = [], closed = false
    let incoming: AsyncStream<LiveSocketFrame>
    let feed: AsyncStream<LiveSocketFrame>.Continuation
    init() { (incoming, feed) = AsyncStream.makeStream(of: LiveSocketFrame.self) }
    func sendText(_ text: String) { texts.append(text) }
    func sendData(_ d: Data) { data.append(d) }
    func close() { closed = true }
}

final class LiveVoiceSessionTests: XCTestCase {
    func testStartFrameThenSamplesInOrderThenEndAndNothingAfter() throws {
        let socket = FakeSocket()
        let round = VoiceRoundRequest(wav: Data(), idempotencyKey: "voice-abc-12345678", goalID: "goal-1", language: .en,
                                      promptEndedAt: Date(timeIntervalSince1970: 1_000), occurredAt: Date(timeIntervalSince1970: 1_001.5))
        let session = LiveVoiceSession(socket: socket, start: LiveStart(round))
        let start = try JSONSerialization.jsonObject(with: Data(socket.texts[0].utf8)) as! NSDictionary
        XCTAssertEqual(start, ["type": "start", "idempotency_key": "voice-abc-12345678", "language": "en", "goal_id": "goal-1",
                               "prompt_ended_at": "1970-01-01T00:16:40.000Z", "occurred_at": "1970-01-01T00:16:41.500Z", "speech": true] as NSDictionary)
        session.send([1, -1, 256][...]); session.send([Int16.max][...])
        session.end()
        session.send([7][...])
        XCTAssertEqual(socket.data, [Data([1, 0, 0xFF, 0xFF, 0, 1]), Data([0xFF, 0x7F])], "little-endian, in order, nothing after end")
        XCTAssertEqual(socket.texts.last, #"{"type":"end"}"#)
        XCTAssertEqual(session.samplesSent, 4)
        // The same samples make the same WAV the fallback upload sends.
        XCTAssertEqual(WAV.encode([1, -1, 256, .max]).dropFirst(44), Data([1, 0, 0xFF, 0xFF, 0, 1, 0xFF, 0x7F]))
    }

    func testEventsAreDecodedInOrderWithTheAudio() async {
        let socket = FakeSocket()
        let session = LiveVoiceSession(socket: socket, start: LiveStart(VoiceRoundRequest(wav: Data(), idempotencyKey: "voice-abc-12345678")))
        let reply = #"{"type":"reply","round_id":"r1","transcript":"Um, maybe.","metrics":{"filler_count":1},"reply":{"move":"challenge","question":"Why maybe?","quote":"maybe","quote_verified":true},"model":"meta-models/muse-spark-open-1026","latency_ms":{"asr":210,"model":1600,"release_to_reply":1830},"transcription":"realtime"}"#
        let saved = #"{"type":"saved","round_id":"r1","receipt_id":"rc1","replayed":false,"transcript":"Um, maybe.","reply":{"move":"challenge","question":"Why maybe?"},"model":"m"}"#
        for frame: LiveSocketFrame in [.text(#"{"type":"ready","transcription":"realtime"}"#), .text(#"{"type":"partial","text":"Um"}"#), .text(#"{"type":"something_new"}"#),
                                       .text(reply), .text(#"{"type":"speech_start","content_type":"audio/mpeg","provider":"wit"}"#), .data(Data([1, 2])),
                                       .text(#"{"type":"speech_end"}"#), .text(saved), .closed(1000)] { socket.feed.yield(frame) }
        socket.feed.finish()
        var seen: [String] = []
        for await event in session.events {
            switch event {
            case .ready(let mode): seen.append("ready \(mode)")
            case .partial(let text): seen.append("partial \(text)")
            case .reply(let r): seen.append("reply \(r.round_id) \(r.reply.question) \(Int(r.latency_ms?.release_to_reply ?? 0))")
            case .speechStart(let type, let provider): seen.append("speech \(type) \(provider ?? "-")")
            case .audio(let d): seen.append("audio \(d.count)")
            case .speechEnd: seen.append("speech end")
            case .saved(let receipt): seen.append("saved \(receipt.receipt_id)")
            case .closed(let code): seen.append("closed \(code ?? -1)")
            default: seen.append("other")
            }
        }
        XCTAssertEqual(seen, ["ready realtime", "partial Um", "reply r1 Why maybe? 1830", "speech audio/mpeg wit", "audio 2", "speech end", "saved rc1", "closed 1000"],
                       "an unknown event is skipped")
        XCTAssertEqual(LiveVoiceEvent.decode(#"{"type":"error","status":429,"error":"rate_limited","message":"At most 60."}"#), .error(.server(429, "rate_limited", "At most 60.")))
    }

    func testTheLiveURLIsTheSameHost() {
        XCTAssertEqual(CoachAPI(baseURL: URL(string: "https://example--web.us-east.modal.run")!, token: "t").liveURL.absoluteString, "wss://example--web.us-east.modal.run/v1/voice-rounds/live")
        XCTAssertEqual(CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "t").liveURL.absoluteString, "ws://127.0.0.1:4319/v1/voice-rounds/live")
    }
}

@MainActor
final class LiveAudioTests: XCTestCase {
    private func waitUntil(_ audio: LiveAudio, waiting count: Int) async {
        for _ in 0..<1_000 where audio.waiting < count { await Task.yield() }
        XCTAssertEqual(audio.waiting, count)
    }

    func testAudioThatEndsBeforeItBeganResumesEveryWaiterWithAFailure() async {
        let audio = LiveAudio()
        let first = Task { try await audio.stream() }, second = Task { try await audio.stream() }
        await waitUntil(audio, waiting: 2)
        audio.finish()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("expected a failure") } catch { XCTAssertEqual(error as? LiveAudio.EndedBeforeAudio, LiveAudio.EndedBeforeAudio()) }
        }
        XCTAssertEqual(audio.waiting, 0)
        // Later calls fail at once, and a late head or a second end changes nothing (no continuation resumes twice).
        audio.start(contentType: "audio/mpeg", provider: "wit")
        audio.finish(); audio.fail(CancellationError())
        do { _ = try await audio.stream(); XCTFail("expected a failure") } catch { XCTAssertTrue(error is LiveAudio.EndedBeforeAudio) }
    }

    func testAHeadThenTheEndHandsOverTheBytesAndCloses() async throws {
        let audio = LiveAudio()
        let waiter = Task { try await audio.stream() }
        await waitUntil(audio, waiting: 1)
        audio.start(contentType: "audio/mpeg", provider: "wit")
        audio.yield(Data("a".utf8)); audio.yield(Data("b".utf8)); audio.finish()
        let stream = try await waiter.value
        XCTAssertEqual(stream.contentType, "audio/mpeg"); XCTAssertEqual(stream.provider, "wit")
        var bytes = Data()
        for try await chunk in stream.chunks { bytes.append(chunk) }
        XCTAssertEqual(bytes, Data("ab".utf8))
        audio.fail(CancellationError()) // after the end: nothing is waiting, nothing resumes
    }

    func testAFailureResumesWaitersOnce() async {
        let audio = LiveAudio()
        let waiter = Task { try await audio.stream() }
        await waitUntil(audio, waiting: 1)
        audio.fail(CoachError.notConfigured); audio.fail(CancellationError()); audio.finish()
        do { _ = try await waiter.value; XCTFail("expected a failure") } catch { XCTAssertEqual(error as? CoachError, .notConfigured) }
    }
}
