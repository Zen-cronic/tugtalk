import Foundation

struct GoalSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let target: String
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
}

struct CaptureReceipt: Decodable {
    let receipt_id: String
    let replayed: Bool
    let record: CapturedSession
}

private struct Overview: Decodable { let goals: [GoalSummary] }
private struct APIErrorBody: Decodable { let error: String; let message: String? }

enum CoachError: LocalizedError {
    case notConfigured
    case server(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add the connector key in Secrets.xcconfig and rebuild."
        case .server(let status, let message): return "\(status): \(message)"
        }
    }
}

/// Talks to the shared coaching backend. The watch keeps no goal state of its own:
/// it reads the same fresh overview every other device reads.
struct CoachAPI {
    let baseURL: URL
    let token: String

    static func fromBundle() throws -> CoachAPI {
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

    func goals() async throws -> [GoalSummary] {
        var request = URLRequest(url: baseURL.appending(path: "v1/overview"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        return try JSONDecoder().decode(Overview.self, from: data).goals
    }

    /// Uploads one WAV. `idempotencyKey` is stored with the file so a retry after a
    /// network drop returns the original receipt instead of creating (and paying for) a duplicate.
    func upload(file: URL, idempotencyKey: String, goalID: String?, language: String, occurredAt: Date) async throws -> CaptureReceipt {
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
        if language == "fr" {
            // The wearer records only their own speech. A French-practice backend requires these;
            // this backend's hosting adapter does not forward them.
            request.setValue("self_only", forHTTPHeaderField: "X-Consent-Basis")
            request.setValue("self_declared", forHTTPHeaderField: "X-Attribution")
            request.setValue("everyday", forHTTPHeaderField: "X-Context")
        }
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try check(data, response)
        return try JSONDecoder().decode(CaptureReceipt.self, from: data)
    }
}

#if DEBUG
extension CaptureReceipt {
    /// Fixed sample shown with the -previewResult launch argument. Not a real capture.
    static let preview = CaptureReceipt(
        receipt_id: "preview", replayed: false,
        record: CapturedSession(
            id: "preview", transcript: "Um, so I think the main point is, uh, ship the smaller version first.",
            metrics: Metrics(word_count: 58, words_per_minute: 128, filler_count: 3, hedge_count: 1, restart_count: 2),
            analysis: Analysis(status: "model_observation",
                               observation: "You reached your main point after three fillers, then restarted twice to sharpen it.",
                               suggested_exercise: "Answer again in one breath, starting with \"The main point is\".",
                               reason: nil)))
}
#endif
