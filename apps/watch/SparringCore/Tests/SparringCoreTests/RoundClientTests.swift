import Foundation
import Testing
@testable import SparringCore

/// Answers requests from a script and records what was sent.
final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let headers: [String: String]; let body: Data; var offline = false }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    static func reset(_ replies: [Reply]) { lock.withLock { self.replies = replies; seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let reply: Reply? = Self.lock.withLock {
            Self.seen.append(request)
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        guard let reply, !reply.offline else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ScriptedProtocol.self]
    return URLSession(configuration: config)
}

private let json = ["Content-Type": "application/json"]
private let okBody = Data("""
{"round_id":"r1","receipt_id":"rc1","replayed":false,"transcript":"So um I could maybe lead the launch.",
 "metrics":{"word_count":8,"words_per_minute":150,"filler_count":1,"hedge_count":1,"restart_count":0,"pauses":{"status":"measured"},"onset_ms_approx":null},
 "reply":{"move":"challenge","question":"Why should it be you?","quote":"maybe lead the launch","quote_verified":true},
 "model":"meta-models/muse-spark-open-1026","provider_request_id":"p1","latency_ms":{"asr":1,"model":2,"total":3},
 "media":{"kept":true,"bytes":10,"sha256":"x"},
 "gate":{"allowed":["follow_up","challenge"],"reason":"open","hedges":1,"coerced":false},"reply_mode":"model",
 "counterpart":{"need":null,"need_met":null,"allowed":["follow_up","challenge"],"reason":"open","answer":1,"reply_mode":"model"}}
""".utf8)
private let base = URL(string: "http://127.0.0.1:4391")!
private let upload = AnswerUpload(idempotencyKey: "watch-voice-abc12345", goalID: "goal-1", language: .en,
                                  occurredAt: Date(timeIntervalSince1970: 1_800_000_000.25), promptEndedAt: Date(timeIntervalSince1970: 1_799_999_998))

// The scripted protocol is shared state, so these run one at a time.
@Suite(.serialized) struct Requests {
    @Test func theAnswerRequestCarriesTheRoundsHeaders() {
        let r = RoundRequests(baseURL: base, token: "t").answer(upload, wav: Data([1, 2, 3]))
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "http://127.0.0.1:4391/v1/voice-rounds")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
        #expect(r.value(forHTTPHeaderField: "Idempotency-Key") == "watch-voice-abc12345")
        #expect(r.value(forHTTPHeaderField: "X-Language") == "en")
        #expect(r.value(forHTTPHeaderField: "X-Goal-Id") == "goal-1")
        #expect(r.value(forHTTPHeaderField: "X-Occurred-At") == "2027-01-15T08:00:00.250Z")
        #expect(r.value(forHTTPHeaderField: "X-Prompt-Ended-At") == "2027-01-15T07:59:58.000Z")
        #expect(r.httpBody == Data([1, 2, 3]))
    }

    @Test func theNeedTravelsAsAHeader() {
        let withNeed = AnswerUpload(idempotencyKey: "watch-voice-2", goalID: nil, language: .en, occurredAt: .now, promptEndedAt: nil, need: "date")
        #expect(RoundRequests(baseURL: base, token: "t").answer(withNeed, wav: Data()).value(forHTTPHeaderField: "X-Counterpart-Need") == "date")
        #expect(RoundRequests(baseURL: base, token: "t").answer(upload, wav: Data()).value(forHTTPHeaderField: "X-Counterpart-Need") == nil)
    }

    @Test func noGoalAndNoQuestionMeansNoHeaders() {
        let bare = AnswerUpload(idempotencyKey: "watch-voice-1", goalID: nil, language: .fr, occurredAt: .now, promptEndedAt: nil)
        let r = RoundRequests(baseURL: base, token: "t").answer(bare, wav: Data())
        #expect(r.value(forHTTPHeaderField: "X-Goal-Id") == nil)
        #expect(r.value(forHTTPHeaderField: "X-Prompt-Ended-At") == nil)
        #expect(r.value(forHTTPHeaderField: "X-Language") == "fr")
    }

    @Test func theSpeechRequestIsAPostForThatRound() {
        let r = RoundRequests(baseURL: base, token: "t").speech(roundID: "8f1c-22")
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "http://127.0.0.1:4391/v1/voice-rounds/8f1c-22/speech")
        #expect(r.value(forHTTPHeaderField: "Accept")?.contains("audio/mpeg") == true)
    }

    @Test func keysAreLongEnoughForTheServer() {
        let key = RoundRequests.newIdempotencyKey()
        #expect((8...128).contains(key.count))
        #expect(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func aServerErrorIsResentWithTheSameKey() async throws {
        ScriptedProtocol.reset([.init(status: 502, headers: json, body: Data(#"{"error":"reply_failed","message":"Reply failed."}"#.utf8)),
                                .init(status: 0, headers: [:], body: Data(), offline: true),
                                .init(status: 200, headers: json, body: okBody)])
        let client = RoundClient(requests: RoundRequests(baseURL: base, token: "t"), session: session(), backoff: { _ in .zero })
        let receipt = try await client.send(upload, wav: Data([0]))
        #expect(receipt.reply.verifiedQuote == "maybe lead the launch")
        #expect(receipt.media?.kept == true && receipt.media?.note == nil)
        #expect(receipt.counterpart == Counterpart(need: nil, need_met: nil, allowed: ["follow_up", "challenge"], reason: "open", answer: 1))
        let keys = ScriptedProtocol.lock.withLock { ScriptedProtocol.seen.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } }
        #expect(keys == Array(repeating: "watch-voice-abc12345", count: 3))
        let stamps = ScriptedProtocol.lock.withLock { Set(ScriptedProtocol.seen.compactMap { $0.value(forHTTPHeaderField: "X-Occurred-At") }) }
        #expect(stamps.count == 1)
    }

    @Test func a429IsNotResent() async {
        ScriptedProtocol.reset([.init(status: 429, headers: json, body: Data(#"{"error":"rate_limited","message":"At most 60 voice rounds per hour."}"#.utf8)),
                                .init(status: 200, headers: json, body: okBody)])
        let client = RoundClient(requests: RoundRequests(baseURL: base, token: "t"), session: session(), backoff: { _ in .zero })
        await #expect(throws: RoundFailure.from(status: 429, code: "rate_limited", message: "At most 60 voice rounds per hour.")) {
            try await client.send(upload, wav: Data([0]))
        }
        #expect(ScriptedProtocol.lock.withLock { ScriptedProtocol.seen.count } == 1)
    }

    @Test func speechUnconfiguredAndNonAudioAreSpeechFailures() async {
        ScriptedProtocol.reset([.init(status: 503, headers: json, body: Data(#"{"error":"speech_unconfigured"}"#.utf8)),
                                .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<p>".utf8))])
        let client = RoundClient(requests: RoundRequests(baseURL: base, token: "t"), session: session())
        do { _ = try await client.speech(roundID: "r1"); Issue.record("expected a failure") } catch {
            #expect(SpeechFailure.reason(for: error) == "the coach has no voice set up")
        }
        do { _ = try await client.speech(roundID: "r1"); Issue.record("expected a failure") } catch {
            #expect(SpeechFailure.reason(for: error) == "the coach voice sent no audio")
        }
    }

    @Test func anMP3ClipIsReturnedWithItsProvider() async throws {
        ScriptedProtocol.reset([.init(status: 200, headers: ["Content-Type": "audio/mpeg", "X-Speech-Provider": "wit"], body: Data([0xFF, 0xFB, 0x90]))])
        let client = RoundClient(requests: RoundRequests(baseURL: base, token: "t"), session: session())
        let clip = try await client.speech(roundID: "r1")
        #expect(clip.contentType == "audio/mpeg" && clip.provider == "wit" && clip.data.count == 3)
        #expect(SpeechVoice.coach(provider: clip.provider).label == nil)
    }
}

// The round end shares the scripted protocol, so its tests join the serialized suite above.
extension Requests {
    @Test func theRoundEndIsAnEmptyJSONBodyWithItsKey() throws {
        let request = RoundRequests(baseURL: base, token: "tok").endRound(idempotencyKey: "watch-round-end-1")
        #expect(request.url?.path == "/v1/voice-rounds/end")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "watch-round-end-1")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(RoundRequests.newRoundEndKey().hasPrefix("watch-round-end-"))
    }

    @Test func aRoundEndOfflineIsResentWithTheSameKeyAndA4xxIsNot() async throws {
        let client = RoundClient(requests: RoundRequests(baseURL: base, token: "tok"), session: session(), maxAttempts: 3, backoff: { _ in .zero })
        let ok = Data(#"{"receipt_id":"rc","saved":true,"replayed":false,"record":{"id":"latest","version":1,"ended_at":"2026-11-02T20:00:00.000Z"}}"#.utf8)
        ScriptedProtocol.reset([ScriptedProtocol.Reply(status: 0, headers: [:], body: Data(), offline: true), ScriptedProtocol.Reply(status: 200, headers: json, body: ok)])
        try await client.endRound(idempotencyKey: "watch-round-end-2")
        #expect(ScriptedProtocol.seen.count == 2)
        #expect(Set(ScriptedProtocol.seen.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }) == ["watch-round-end-2"])
        ScriptedProtocol.reset([ScriptedProtocol.Reply(status: 400, headers: json, body: Data(#"{"error":"unknown_field","message":"m"}"#.utf8))])
        await #expect(throws: RoundFailure.self) { try await client.endRound(idempotencyKey: "watch-round-end-3") }
        #expect(ScriptedProtocol.seen.count == 1)
    }
}

extension Requests {
    @Test func theScreenCardIsSentOnlyWhenPicked() {
        let requests = RoundRequests(baseURL: base, token: "tok")
        #expect(requests.answer(upload, wav: Data()).value(forHTTPHeaderField: "X-Screen-Context-Id") == nil)
        let carded = AnswerUpload(idempotencyKey: "watch-voice-card1234", goalID: "goal-1", language: .en, occurredAt: upload.occurredAt, promptEndedAt: nil,
                                  screenContextID: "card-goal")
        #expect(requests.answer(carded, wav: Data()).value(forHTTPHeaderField: "X-Screen-Context-Id") == "card-goal")
    }
}
