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
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try check(data, response)
        return try JSONDecoder().decode(CaptureReceipt.self, from: data)
    }
}
