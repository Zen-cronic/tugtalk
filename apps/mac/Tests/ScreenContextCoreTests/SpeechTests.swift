import Foundation
import XCTest
@testable import ScreenContextCore

/// A speaker that records calls; the test plays its events by hand.
@MainActor
final class FakeSpeaker: ReplySpeaker {
    var spoken: [SpokenLine] = []
    var stops = 0
    var events: SpeechEvents?
    func speak(_ line: SpokenLine, events: SpeechEvents) { spoken.append(line); self.events = events }
    func stop() { stops += 1 }
}

@MainActor
final class SpeechRouterTests: XCTestCase {
    private let line = SpokenLine(text: "Why you?", language: .en, roundID: "vr1")
    private var sources: [SpeechSource] = []
    private var finishes: [Date] = []

    private func speak(_ router: SpeechRouter, _ line: SpokenLine) {
        router.speak(line, started: { self.sources.append($0) }, finished: { self.finishes.append($0) })
    }

    override func setUp() async throws { sources = []; finishes = [] }

    func testTheRemoteVoiceIsTheDefault() {
        let remote = FakeSpeaker(), apple = FakeSpeaker()
        let router = SpeechRouter(remote: remote, fallback: apple)
        speak(router, line)
        XCTAssertEqual(remote.spoken, [line]); XCTAssertEqual(apple.spoken, [])
        remote.events?.started("wit")
        let end = Date(timeIntervalSince1970: 5)
        remote.events?.finished(end)
        XCTAssertEqual(sources, [.remote(provider: "wit")]); XCTAssertEqual(sources.first?.label, "Wit.ai voice, through the coach"); XCTAssertEqual(finishes, [end], "the finish time feeds X-Prompt-Ended-At")
        XCTAssertFalse(router.isSpeaking)
    }

    func testA503NetworkErrorOrSlowStartFallsBackToTheAppleVoice() {
        let cases: [(Error, String)] = [
            (CoachError.server(503, "speech_unconfigured", "No key."), "the coach has no voice set up"),
            (CoachError.offline("x"), "the coach voice could not be reached"),
            (SpeechFetchError.timedOut, "the coach voice took over 2 s to start"),
        ]
        for (error, reason) in cases {
            sources = []
            let remote = FakeSpeaker(), apple = FakeSpeaker()
            let router = SpeechRouter(remote: remote, fallback: apple)
            speak(router, line)
            remote.events?.failed(error)
            XCTAssertEqual(apple.spoken, [line], "\(error)")
            apple.events?.started(nil)
            XCTAssertEqual(sources, [.fallback(reason: reason)], "the card shows a fallback-voice note")
            apple.events?.finished(Date(timeIntervalSince1970: 9))
            XCTAssertEqual(finishes.last, Date(timeIntervalSince1970: 9))
        }
    }

    func testNoRoundOrNoRemoteMeansTheAppleVoice() {
        let apple = FakeSpeaker()
        speak(SpeechRouter(remote: nil, fallback: apple), line)
        XCTAssertEqual(apple.spoken, [line])
        let remote = FakeSpeaker(), apple2 = FakeSpeaker()
        speak(SpeechRouter(remote: remote, fallback: apple2), SpokenLine(text: "Q", language: .fr, roundID: nil))
        XCTAssertEqual(remote.spoken, []); XCTAssertEqual(apple2.spoken.count, 1)
    }

    func testBargeInStopsBothVoicesAndSilencesLateEvents() {
        let remote = FakeSpeaker(), apple = FakeSpeaker()
        let router = SpeechRouter(remote: remote, fallback: apple)
        speak(router, line)
        let pending = remote.events
        router.stop()
        XCTAssertEqual(remote.stops, 2, "stopped before speaking and on barge-in"); XCTAssertEqual(apple.stops, 2)
        pending?.failed(CoachError.offline("late"))
        XCTAssertEqual(apple.spoken, [], "a failure after barge-in does not start the fallback voice")
        pending?.started(nil); pending?.finished(Date())
        XCTAssertEqual(sources, []); XCTAssertEqual(finishes, [], "nothing is reported for a stopped question")

        // Barge-in while the fallback voice is playing.
        speak(router, line)
        remote.events?.failed(CoachError.offline("x"))
        apple.events?.started(nil)
        let applePending = apple.events
        router.stop()
        XCTAssertEqual(apple.stops, 4)
        applePending?.finished(Date())
        XCTAssertEqual(finishes, [], "a stopped question has no end time")
    }
}

/// Answers a speech request after an optional delay.
final class SpeechProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var contentType = "audio/mpeg"
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var extraHeaders: [String: String] = [:]
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": Self.contentType].merging(Self.extraHeaders) { a, _ in a })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { cancelled = true }
}

final class SpeechFetchTests: XCTestCase {
    private func api() -> CoachAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechProtocol.self]
        return CoachAPI(baseURL: URL(string: "http://127.0.0.1:4319")!, token: "local-test-token", session: URLSession(configuration: configuration))
    }

    override func setUp() {
        SpeechProtocol.status = 200; SpeechProtocol.contentType = "audio/mpeg"; SpeechProtocol.delay = 0
        SpeechProtocol.body = Data([0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 1, count: 2000)); SpeechProtocol.requests = []; SpeechProtocol.extraHeaders = [:]
    }

    func testAWAVFromAMetaVoiceKeepsItsProviderForTheCard() async throws {
        SpeechProtocol.contentType = "audio/wav; charset=binary"
        SpeechProtocol.body = WAV.encode([1, 2, 3])
        SpeechProtocol.extraHeaders = ["X-Speech-Provider": "mms", "X-Speech-Voice": "facebook/mms-tts-eng"]
        let audio = try await api().fetchSpeech(roundID: "vr-2")
        XCTAssertTrue(audio.isWAV); XCTAssertEqual(audio.contentType, "audio/wav")
        XCTAssertEqual(audio.provider, "mms"); XCTAssertEqual(audio.voice, "facebook/mms-tts-eng")
        XCTAssertEqual(SpeechSource.remote(provider: audio.provider).label, "Meta MMS-TTS voice, through the coach")
        XCTAssertEqual(SpeechSource.remote(provider: nil).label, "The coach's voice")
    }

    func testRawPCMCannotBePlayedSoTheFallbackSpeaks() async {
        SpeechProtocol.contentType = "audio/pcm"
        do { _ = try await api().fetchSpeech(roundID: "vr-1"); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? SpeechFetchError, .unplayable("audio/pcm"))
        }
    }

    func testTheRoundsAudioIsFetchedWithTheKeyOnTheSameHost() async throws {
        let audio = try await api().fetchSpeech(roundID: "vr-1")
        XCTAssertEqual(audio.data, SpeechProtocol.body); XCTAssertFalse(audio.isWAV)
        let request = try XCTUnwrap(SpeechProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/v1/voice-rounds/vr-1/speech")
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/wav, audio/mpeg")
    }

    func testNoVoiceKeyOnTheServerIsATyped503() async {
        SpeechProtocol.status = 503; SpeechProtocol.contentType = "application/json"
        SpeechProtocol.body = Data(#"{"error":"speech_unconfigured","message":"No ElevenLabs key."}"#.utf8)
        do { _ = try await api().fetchSpeech(roundID: "vr-1"); XCTFail("expected 503") } catch {
            XCTAssertEqual(error as? CoachError, .server(503, "speech_unconfigured", "No ElevenLabs key."))
            XCTAssertEqual(SpeechRouter.reason(for: error), "the coach has no voice set up")
        }
    }

    func testNoAudioWithinTheFirstAudioLimitTimesOut() async {
        SpeechProtocol.delay = 1.0
        let started = Date()
        do { _ = try await api().fetchSpeech(roundID: "vr-1", firstAudio: .milliseconds(200)); XCTFail("expected a timeout") } catch {
            XCTAssertEqual(error as? SpeechFetchError, .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.8, "it gives up at the limit, not when the audio finally arrives")
        }
    }

    func testAnswersThatAreNotAudioAreRefused() async {
        SpeechProtocol.contentType = "text/html"
        do { _ = try await api().fetchSpeech(roundID: "vr-1"); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? SpeechFetchError, .notAudio("text/html"))
        }
    }
}
