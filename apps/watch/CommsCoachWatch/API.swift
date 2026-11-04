import Foundation
import SparringCore

struct GoalSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let target: String
    /// The goal's newest screen card from the Mac (id and time only), if any. A spoken round on the wrist is about it.
    var latest_screen_context: ScreenCard? = nil
}

struct Metrics: Decodable {
    let word_count: Int
    let words_per_minute: Int?
    let filler_count: Int
    let hedge_count: Int
    let restart_count: Int
}

struct Analysis: Decodable {
    let status: String
    let observation: String?
    let suggested_exercise: String?
    let reason: String?
}

struct CapturedSession: Decodable {
    let id: String
    let transcript: String
    let metrics: Metrics
    let analysis: Analysis
    /// Present only when Keep my recordings is on.
    var media: KeptMedia? = nil
    /// Present only when the capture named a drill (X-Exercise-Id); see Drill.swift.
    var drill: DrillOutcome? = nil
}

/// "Keep my recordings": the account's setting on the coach server, off by default. Off, audio is deleted after
/// transcription; on, each recording stays in the account until it is deleted.
struct KeptCounts: Decodable { let recordings: Int; let bytes: Int }
struct CoachSettings: Decodable { let keep_recordings: Bool; let version: Int; let kept: KeptCounts? }
private struct SettingsBody: Decodable { let settings: CoachSettings }

/// The `media` block on a saved recording.
struct KeptMedia: Decodable {
    let kept: Bool
    let reason: String?
    /// The line the result shows, or nil.
    var note: String? { kept ? "Recording kept" : (reason == "full" ? "Recording not kept: storage full" : nil) }
}

struct CaptureReceipt: Decodable {
    let receipt_id: String
    let replayed: Bool
    let record: CapturedSession
}

/// The fresh overview, as the watch reads it: the goals, and the account's newest screen card.
struct Overview: Decodable {
    let goals: [GoalSummary]
    var latest_screen_context: ScreenCard? = nil
}
private struct APIErrorBody: Decodable { let error: String; let message: String? }

enum CoachError: LocalizedError {
    case notConfigured
    case server(Int, String)
    /// The server refused this recording and would refuse the same request again, so no Retry. Plain words for the wrist.
    case refused(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add the connector key in Secrets.xcconfig and rebuild."
        case .server(let status, let message): return "\(status): \(message)"
        case .refused(let message): return message
        }
    }
}

/// Talks to the shared coaching backend. The watch keeps no goal state of its own:
/// it reads the same fresh overview every other device reads.
struct CoachAPI {
    let baseURL: URL
    let token: String

    static func fromBundle() throws -> CoachAPI {
        #if DEBUG
        // Debug builds only: `-devBaseURL http://127.0.0.1:4319 -devTokenFile <path>` talks to the local stub
        // server (scripts/local-stub-server.mjs) with its throwaway key. Any host but this machine is refused,
        // and the bundled key is not used in this mode.
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "devBaseURL") {
            guard let base = URL(string: raw), ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
                  let host = base.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host),
                  let path = defaults.string(forKey: "devTokenFile"),
                  let token = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
            else { throw CoachError.notConfigured }
            return CoachAPI(baseURL: base, token: token)
        }
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        guard let base = (info["CoachAPIBaseURL"] as? String).flatMap(URL.init(string:)),
              let token = info["CoachAPIToken"] as? String, token.count >= 32 else { throw CoachError.notConfigured }
        return CoachAPI(baseURL: base, token: token)
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            throw CoachError.server(status, body?.message ?? body?.error ?? "Request failed")
        }
    }

    func overview() async throws -> Overview {
        var request = URLRequest(url: baseURL.appending(path: "v1/overview"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        return try JSONDecoder().decode(Overview.self, from: data)
    }

    func settings() async throws -> CoachSettings {
        var request = URLRequest(url: baseURL.appending(path: "v1/settings"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        return try JSONDecoder().decode(SettingsBody.self, from: data).settings
    }

    /// Turns Keep my recordings on or off. `deleteKept` (only when turning it off) also deletes what is kept.
    func setKeepRecordings(_ keep: Bool, deleteKept: Bool, expectedVersion: Int) async throws -> CoachSettings {
        var request = URLRequest(url: baseURL.appending(path: "v1/settings"))
        request.httpMethod = "PATCH"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("watch-settings-\(UUID().uuidString)", forHTTPHeaderField: "Idempotency-Key")
        var body: [String: Any] = ["expected_version": expectedVersion, "keep_recordings": keep]
        if !keep && deleteKept { body["delete_kept_recordings"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        return try JSONDecoder().decode(SettingsBody.self, from: data).settings
    }

    /// Uploads one WAV. `idempotencyKey` is stored with the file so a retry after a
    /// network drop returns the original receipt instead of creating (and paying for) a duplicate.
    func upload(file: URL, idempotencyKey: String, goalID: String?, language: String, occurredAt: Date, exerciseID: String? = nil) async throws -> CaptureReceipt {
        var request = URLRequest(url: baseURL.appending(path: "v1/recordings"))
        request.httpMethod = "POST"
        request.timeoutInterval = 170
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("watch", forHTTPHeaderField: "X-Capture-Device")
        request.setValue(language, forHTTPHeaderField: "X-Language")
        request.setValue(ISO8601DateFormatter().string(from: occurredAt), forHTTPHeaderField: "X-Occurred-At")
        if let goalID { request.setValue(goalID, forHTTPHeaderField: "X-Goal-Id") }
        if let exerciseID { request.setValue(exerciseID, forHTTPHeaderField: "X-Exercise-Id") } // the open drill: measured against its basis
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        if let refusal = Self.refusal(data, response) { throw CoachError.refused(refusal) }
        try check(data, response)
        return try JSONDecoder().decode(CaptureReceipt.self, from: data)
    }

    /// A recording the server will always refuse (src/capture.mjs, src/server.mjs, src/store.mjs), in a few words.
    /// Nil for any other answer, which `check` handles as before.
    static func refusal(_ data: Data, _ response: URLResponse) -> String? {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (400..<500).contains(status) else { return nil }
        switch (status, (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error) {
        case (413, _): return "Recording too large."
        case (_, "unsupported_audio"): return "Recording format not supported."
        case (_, "audio_too_long"): return "Recording too long."
        case (409, "idempotency_conflict"): return "Already sent. Record again."
        default: return nil
        }
    }
}

#if DEBUG
extension CaptureReceipt {
    /// Shown with the -previewResult launch argument; not a watch capture. The values are copied from one
    /// recorded run of the hosted pipeline: a synthetic voice clip uploaded with curl on Nov 1, 2026
    /// (receipt 5aeff421, session 92a20be9), with its observation and exercise verbatim.
    /// `kept`: the result as it looks with Keep my recordings on (`-previewRecordingKept`).
    static func preview(observation: String? = nil, kept: Bool = false) -> CaptureReceipt {
        guard observation != nil || kept else { return preview }
        let r = preview.record
        return CaptureReceipt(receipt_id: preview.receipt_id, replayed: false,
                              record: CapturedSession(id: r.id, transcript: r.transcript, metrics: r.metrics,
                                                      analysis: Analysis(status: r.analysis.status, observation: observation ?? r.analysis.observation,
                                                                         suggested_exercise: r.analysis.suggested_exercise, reason: nil),
                                                      media: kept ? KeptMedia(kept: true, reason: nil) : nil))
    }

    static let preview = CaptureReceipt(
        receipt_id: "preview", replayed: false,
        record: CapturedSession(
            id: "preview", transcript: "Um, so I think the main point is basically that we should ship the smaller version first. Sorry, let me restart. The main point is ship the smaller version first because it lets us test with real users this week",
            metrics: Metrics(word_count: 40, words_per_minute: 166, filler_count: 2, hedge_count: 1, restart_count: 2),
            analysis: Analysis(status: "model_observation",
                               observation: "You met the goal after restarting, stating 'The main point is ship the smaller version first' followed by one supporting detail 'it lets us test with real users this week'. In 40 words at 166 wpm you had 2 fillers, 1 hedge, and 2 restarts including 'Sorry, let me restart' and the initial 'Um, so I think'.",
                               suggested_exercise: "60-second reset drill (under 2 minutes): Record yourself 3 times saying only 'The main point is ship the smaller version first because it lets us test with real users this week' — no fillers or hedges, pause 5 seconds between takes.",
                               reason: nil)))
}
#endif
