@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import ScreenContextCore

final class WAVTests: XCTestCase {
    func testHeaderIsCanonicalMono16BitAt24kHz() throws {
        let samples: [Int16] = [0, 1, -1, .max, .min, 1234]
        let data = WAV.encode(samples)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        let bytes = [UInt8](data)
        let u32 = { (at: Int) in Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        XCTAssertEqual(u32(4), 36 + samples.count * 2, "RIFF size")
        XCTAssertEqual(u32(24), 24_000, "sample rate")
        XCTAssertEqual(u32(28), 48_000, "byte rate")
        XCTAssertEqual(u32(40), samples.count * 2, "data size")
        let header = try XCTUnwrap(WAV.header(of: data))
        XCTAssertEqual(header, WAV.Header(format: 1, channels: 1, sampleRate: 24_000, bitsPerSample: 16, dataBytes: 12))
        // Samples are little-endian.
        XCTAssertEqual(Array(bytes[50..<52]), [0xFF, 0x7F], "Int16.max")
        XCTAssertEqual(Array(bytes[52..<54]), [0x00, 0x80], "Int16.min")
    }

    func testSixteenKilohertzAndDuration() throws {
        let header = try XCTUnwrap(WAV.header(of: WAV.encode([Int16](repeating: 0, count: 16_000), sampleRate: 16_000)))
        XCTAssertEqual(header.sampleRate, 16_000)
        XCTAssertEqual(header.durationSeconds, 1, accuracy: 0.0001)
        XCTAssertNil(WAV.header(of: Data("not a wav".utf8)))
    }

    func testAVFoundationReadsWhatWeWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wav-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.wav")
        try WAV.encode(sine(seconds: 0.5, rate: 24_000)).write(to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 12_000)
    }
}

final class ResamplerTests: XCTestCase {
    func testStereo48kFloatBecomesMono24kInt16() throws {
        let input = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let resampler = try XCTUnwrap(PCMResampler(from: input))
        var out: [Int16] = []
        // One second in mic-sized buffers, the way the input tap delivers it.
        for _ in 0..<(48_000 / 4_800) {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            for channel in 0..<2 {
                let data = try XCTUnwrap(buffer.floatChannelData?[channel])
                for i in 0..<4_800 { data[i] = 0.5 * sinf(Float(out.count + i) * 2 * .pi * 440 / 48_000) }
            }
            out += resampler.convert(buffer)
        }
        out += resampler.finish()
        XCTAssertEqual(Double(out.count), 24_000, accuracy: 100, "half the frames at half the rate")
        XCTAssertGreaterThan(out.map { abs(Int($0)) }.max() ?? 0, 10_000, "the tone survives the conversion")
    }

    func testAFixtureFileAt16kIsConvertedAndCappedAt60Seconds() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wav-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let short = dir.appending(path: "short.wav")
        try WAV.encode(sine(seconds: 2, rate: 16_000), sampleRate: 16_000).write(to: short)
        XCTAssertEqual(Double(try PCMResampler.convertFile(at: short).count), 48_000, accuracy: 100)
        let long = dir.appending(path: "long.wav")
        try WAV.encode([Int16](repeating: 100, count: 16_000 * 61), sampleRate: 16_000).write(to: long)
        XCTAssertEqual(try PCMResampler.convertFile(at: long).count, 60 * 24_000, "a hold keeps at most 60 s")
    }
}

final class VoiceClipStoreTests: XCTestCase {
    func testTheClipIsPrivateAndGoneAfterRemoveOrSweep() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceClipStore(root: root)
        let url = try store.write(WAV.encode([1, 2, 3]), for: "voice-abc")
        XCTAssertTrue(store.exists("voice-abc"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try store.read("voice-abc").count, 50)
        store.remove("voice-abc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "the hold directory is deleted")
        try store.write(WAV.encode([1]), for: "voice-left-behind")
        try Data().write(to: root.appending(path: "unrelated.txt"))
        XCTAssertEqual(store.sweep(), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated.txt"], "the sweep touches only hold directories")
    }
}

/// Plays back a scripted list of answers, one per request, and records what the client sent.
final class SequenceProtocol: URLProtocol, @unchecked Sendable {
    enum Answer { case status(Int, String), networkLost }
    nonisolated(unsafe) static var answers: [Answer] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close(); Self.bodies.append(data)
        } else { Self.bodies.append(request.httpBody ?? Data()) }
        let answer = Self.answers.isEmpty ? .status(500, "{}") : Self.answers.removeFirst()
        switch answer {
        case .networkLost:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

let voiceReceiptJSON = #"{"round_id":"vr1","receipt_id":"rc1","replayed":false,"transcript":"Um, I think maybe I should lead it.","metrics":{"word_count":8,"words_per_minute":132.5,"filler_count":1,"hedge_count":2,"restart_count":0,"pauses":{"count":1,"longest_ms":900},"onset_ms_approx":1200},"reply":{"move":"challenge","question":"You said maybe. Why should Dana pick you?","quote":"maybe I should lead it","quote_verified":true},"model":"meta-models/muse-spark-open-1026","provider_request_id":"chatcmpl-1","latency_ms":{"asr":2100,"model":1700,"total":3900},"extra":true}"#

final class VoiceRoundAPITests: XCTestCase {
    private func api() -> CoachAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SequenceProtocol.self]
        return CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "local-test-token", session: URLSession(configuration: configuration))
    }

    override func setUp() { SequenceProtocol.requests = []; SequenceProtocol.bodies = []; SequenceProtocol.answers = [] }

    func testTheRequestCarriesTheContractHeadersAndTheWAVBody() async throws {
        SequenceProtocol.answers = [.status(200, voiceReceiptJSON)]
        let wav = WAV.encode([1, 2, 3, 4])
        let ended = Date(timeIntervalSince1970: 1_793_000_000.25)
        let receipt = try await api().postVoiceRound(VoiceRoundRequest(wav: wav, idempotencyKey: "voice-k1", goalID: "g1", screenContextID: "c1", language: .fr,
                                                                       promptEndedAt: ended, occurredAt: ended.addingTimeInterval(1.5)))
        let request = try XCTUnwrap(SequenceProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/voice-rounds"); XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "voice-k1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goal-Id"), "g1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Screen-Context-Id"), "c1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Language"), "fr")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Prompt-Ended-At"), "2026-10-26T07:33:20.250Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Occurred-At"), "2026-10-26T07:33:21.750Z", "the hold's start, for the onset")
        XCTAssertEqual(SequenceProtocol.bodies.first, wav)
        XCTAssertEqual(receipt.reply.kind, .challenge)
        XCTAssertEqual(receipt.reply.verifiedQuote, "maybe I should lead it")
        XCTAssertEqual(receipt.latency_ms?.total, 3900)
        XCTAssertEqual(receipt.metrics?.filler_count, 1)
    }

    func testOptionalHeadersAreLeftOutWhenUnknown() async throws {
        SequenceProtocol.answers = [.status(200, voiceReceiptJSON)]
        _ = try await api().postVoiceRound(VoiceRoundRequest(wav: WAV.encode([0]), idempotencyKey: "voice-k2"))
        let request = try XCTUnwrap(SequenceProtocol.requests.first)
        for header in ["X-Goal-Id", "X-Screen-Context-Id", "X-Prompt-Ended-At", "X-Occurred-At"] { XCTAssertNil(request.value(forHTTPHeaderField: header), header) }
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Language"), "en")
    }

    func testAnUnverifiedQuoteIsNotShown() throws {
        let reply = try JSONDecoder().decode(VoiceReply.self, from: Data(#"{"move":"follow_up","question":"q","quote":"made up","quote_verified":false}"#.utf8))
        XCTAssertNil(reply.verifiedQuote)
        XCTAssertNil(try JSONDecoder().decode(VoiceReply.self, from: Data(#"{"move":"wrap_up","question":"q"}"#.utf8)).verifiedQuote)
    }

    func testRetriesReuseTheSameIdempotencyKey() async throws {
        SequenceProtocol.answers = [.networkLost, .status(503, #"{"error":"unavailable","message":"Try again."}"#), .status(200, voiceReceiptJSON)]
        let uploader = VoiceRoundUploader(api: api(), maxAttempts: 3, backoff: { _ in .zero })
        let receipt = try await uploader.send(VoiceRoundRequest(wav: WAV.encode([5]), idempotencyKey: "voice-same"))
        XCTAssertEqual(receipt.round_id, "vr1")
        XCTAssertEqual(SequenceProtocol.requests.count, 3)
        XCTAssertEqual(Set(SequenceProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["voice-same"], "one key for every attempt")
        XCTAssertEqual(Set(SequenceProtocol.bodies), [WAV.encode([5])], "the same clip every attempt")
    }

    func testClientErrorsAreNotRetriedAndRetriesStopAtTheCap() async {
        for (code, name) in [(400, "invalid_audio"), (401, "unauthorized"), (409, "idempotency_conflict"), (413, "too_large"), (429, "rate_limited"),
                             (503, "reply_unconfigured")] {
            SequenceProtocol.requests = []
            SequenceProtocol.answers = [.status(code, #"{"error":"\#(name)","message":"m"}"#), .status(200, voiceReceiptJSON)]
            do {
                _ = try await VoiceRoundUploader(api: api(), backoff: { _ in .zero }).send(VoiceRoundRequest(wav: Data(), idempotencyKey: "k"))
                XCTFail("\(code) should fail")
            } catch {
                XCTAssertEqual(error as? CoachError, .server(code, name, "m"))
            }
            XCTAssertEqual(SequenceProtocol.requests.count, 1, "\(code) is not retried")
        }
        SequenceProtocol.requests = []
        SequenceProtocol.answers = [.status(502, "{}"), .status(502, "{}"), .status(502, "{}"), .status(200, voiceReceiptJSON)]
        do { _ = try await VoiceRoundUploader(api: api(), maxAttempts: 3, backoff: { _ in .zero }).send(VoiceRoundRequest(wav: Data(), idempotencyKey: "k")); XCTFail("expected 502") } catch {
            XCTAssertEqual((error as? CoachError)?.isRetryable, true, "the error card offers Retry")
        }
        XCTAssertEqual(SequenceProtocol.requests.count, 3, "at most three attempts")
    }
}

final class VoiceTurnMachineTests: XCTestCase {
    private func machine() -> VoiceTurnMachine {
        let counter = Counter()
        return VoiceTurnMachine(newKey: { "k\(counter.next())" })
    }
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testAHoldSendsOnReleaseThenSpeaksTheWholeReply() {
        var m = machine()
        XCTAssertEqual(m.keyDown(at: t0), [.startRecording(key: "k1")])
        XCTAssertEqual(m.keyDown(at: t0 + 0.5), [], "key repeat while held does nothing")
        XCTAssertEqual(m.keyUp(at: t0 + 3), [.upload(key: "k1", promptEndedAt: nil)])
        XCTAssertEqual(m.keyDown(at: t0 + 3.5), [], "no second round while one is on its way")
        XCTAssertEqual(m.replyReady(key: "old", question: "stale", endsRound: false), [], "a reply for another hold is ignored")
        XCTAssertEqual(m.replyReady(key: "k1", question: " Why you? ", endsRound: false), [.discard(key: "k1"), .speak("Why you?")])
        XCTAssertEqual(m.phase, .speaking(key: "k1", question: "Why you?", endsRound: false))
    }

    func testBargeInStopsSpeechAtOnceAndStartsANewHoldWithNoPromptEnd() {
        var m = machine()
        _ = m.keyDown(at: t0); _ = m.keyUp(at: t0 + 2); _ = m.replyReady(key: "k1", question: "Why you?", endsRound: false)
        XCTAssertEqual(m.keyDown(at: t0 + 4), [.stopSpeaking, .startRecording(key: "k2")], "stop first, then open the microphone")
        XCTAssertEqual(m.phase, .listening(key: "k2", since: t0 + 4, promptEndedAt: nil))
        XCTAssertEqual(m.speechFinished(at: t0 + 4.1), [], "a late finish from the stopped question changes nothing")
        XCTAssertEqual(m.keyUp(at: t0 + 6), [.upload(key: "k2", promptEndedAt: nil)], "a cut-off question has no end time to send")
        XCTAssertNotEqual("k1", "k2")
    }

    func testAFinishedQuestionsEndTimeGoesWithTheNextHoldOnce() {
        var m = machine()
        _ = m.keyDown(at: t0); _ = m.keyUp(at: t0 + 2); _ = m.replyReady(key: "k1", question: "Why you?", endsRound: false)
        XCTAssertEqual(m.speechFinished(at: t0 + 6), [])
        XCTAssertEqual(m.phase, .idle); XCTAssertEqual(m.promptEndedAt, t0 + 6)
        XCTAssertEqual(m.keyDown(at: t0 + 7.2), [.startRecording(key: "k2")])
        XCTAssertEqual(m.keyUp(at: t0 + 7.3), [.discard(key: "k2"), .tooShort], "a tap is not sent")
        XCTAssertEqual(m.promptEndedAt, t0 + 6, "and does not use up the end time")
        _ = m.keyDown(at: t0 + 8)
        XCTAssertEqual(m.keyUp(at: t0 + 10), [.upload(key: "k3", promptEndedAt: t0 + 6)])
        _ = m.uploadFailed(key: "k3", retryable: false)
        _ = m.keyDown(at: t0 + 11)
        XCTAssertEqual(m.keyUp(at: t0 + 13), [.upload(key: "k4", promptEndedAt: nil)], "used once")
    }

    func testWrapUpEndsTheRoundAndOldPromptsExpire() {
        var m = machine()
        _ = m.keyDown(at: t0); _ = m.keyUp(at: t0 + 2); _ = m.replyReady(key: "k1", question: "Thanks, that's all.", endsRound: true)
        _ = m.speechFinished(at: t0 + 4)
        XCTAssertNil(m.promptEndedAt, "a new round starts fresh")
        _ = m.keyDown(at: t0 + 5); _ = m.keyUp(at: t0 + 7); _ = m.replyReady(key: "k2", question: "Go on?", endsRound: false)
        _ = m.speechFinished(at: t0 + 9)
        _ = m.keyDown(at: t0 + 9 + VoiceTurnMachine.promptExpiry + 1)
        XCTAssertEqual(m.keyUp(at: t0 + 9 + VoiceTurnMachine.promptExpiry + 3), [.upload(key: "k3", promptEndedAt: nil)])
    }

    func testRetryReusesTheKeyAndDismissCleansUp() {
        var m = machine()
        _ = m.keyDown(at: t0); _ = m.keyUp(at: t0 + 2)
        XCTAssertEqual(m.uploadFailed(key: "k1", retryable: true), [], "the clip is kept for Retry")
        XCTAssertEqual(m.retry(at: t0 + 5), [.upload(key: "k1", promptEndedAt: nil)], "same key, same clip")
        XCTAssertEqual(m.uploadFailed(key: "k1", retryable: true), [])
        XCTAssertEqual(m.dismiss(), [.discard(key: "k1")], "closing the error deletes the clip")
        _ = m.keyDown(at: t0 + 6); _ = m.keyUp(at: t0 + 8)
        XCTAssertEqual(m.uploadFailed(key: "k2", retryable: false), [.discard(key: "k2")])
        XCTAssertEqual(m.retry(at: t0 + 9), [], "no Retry for a 4xx")
        XCTAssertEqual(m.keyDown(at: t0 + 10), [.discard(key: "k2"), .startRecording(key: "k3")])
        _ = m.keyUp(at: t0 + 12); _ = m.replyReady(key: "k3", question: "Q", endsRound: false)
        XCTAssertEqual(m.dismiss(), [.stopSpeaking])
        XCTAssertNil(m.promptEndedAt)
    }

    func testTheCapSendsEvenAShortHoldAndAnEmptyQuestionFails() {
        var m = machine()
        _ = m.keyDown(at: t0)
        XCTAssertEqual(m.keyUp(at: t0 + 0.1, capped: true), [.upload(key: "k1", promptEndedAt: nil)])
        XCTAssertEqual(m.replyReady(key: "k1", question: "  ", endsRound: false), [.discard(key: "k1")])
        XCTAssertEqual(m.phase, .failed(key: "k1", retryable: false, promptEndedAt: nil))
    }
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private func sine(seconds: Double, rate: Int) -> [Int16] {
    (0..<Int(seconds * Double(rate))).map { Int16(12_000 * sin(Double($0) * 2 * .pi * 440 / Double(rate))) }
}

