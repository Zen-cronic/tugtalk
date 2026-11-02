import Foundation

// Fresh-read shapes. Decodable ignores fields it does not name, so newer servers stay compatible.

public struct GoalProgress: Decodable, Sendable, Equatable {
    public let pending_exercises: Int
    public let measured_sessions: Int
    public let screen_contexts: Int?
}

public struct MeasurementBrief: Decodable, Sendable, Equatable {
    public let id: String
    public let capture_device: String?
}

public struct ScreenContextBrief: Decodable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let app_name: String?
    public let goal_id: String?
    public let summary: String?
    public let observation: String?
    public let next_step: String?
}

public struct GoalSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let version: Int
    public let title: String
    public let target: String
    public let progress: GoalProgress
    public let latest_measurement: MeasurementBrief?
}

public struct Overview: Decodable, Sendable, Equatable {
    public let as_of: String
    public let snapshot_revision: String
    public let request_id: String?
    public let goals: [GoalSummary]
    public let latest_screen_context: ScreenContextBrief?
}

public struct Exercise: Decodable, Sendable, Equatable {
    public let id: String
    public let goal_id: String
    public let title: String
    public let instructions: String
    public let updated_at: String
}

public struct CheckIn: Decodable, Sendable, Equatable {
    public let exercise_id: String
}

public struct GoalContext: Decodable, Sendable, Equatable {
    public let goal: GoalSummary
    public let exercises: [Exercise]
    public let check_ins: [CheckIn]

    /// The newest assigned exercise without a check-in.
    public var newestPending: Exercise? {
        let done = Set(check_ins.map(\.exercise_id))
        return exercises.filter { !done.contains($0.id) }.max { ($0.updated_at, $0.id) < ($1.updated_at, $1.id) }
    }
}

public struct ScreenContextAnalysis: Decodable, Sendable, Equatable {
    public let status: String
    public let summary: String
    public let observation: String
    public let next_step: String
    public let model: String
}

public struct ScreenContextRecord: Decodable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let app_name: String?
    public let goal_id: String?
    /// The capture's language ("en", "fr"), when the server sends it.
    public let language: String?
    public let text_retained: Bool
    public let pixels_sent: Bool
    public let analysis: ScreenContextAnalysis
}

public struct ScreenContextReceipt: Decodable, Sendable, Equatable {
    public let receipt_id: String
    public let replayed: Bool
    public let record_version: Int
    public let record: ScreenContextRecord
}

public struct UndoReceipt: Decodable, Sendable, Equatable {
    public let receipt_id: String
    public let record_version: Int
}

private struct APIErrorBody: Decodable { let error: String; let message: String? }

public enum CoachError: LocalizedError, Equatable {
    case notConfigured
    case server(Int, String, String)
    case offline(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add the connector key to the Keychain, then reopen the companion."
        case .server(429, _, let message): return "\(message) Try again later."
        case .server(let status, _, let message): return "\(status): \(message)"
        case .offline(let reason): return reason
        }
    }

    /// Worth retrying with the same idempotency key. Not a 429: the hourly limit will not lift in seconds.
    public var isRetryable: Bool {
        switch self {
        case .offline: return true
        case .server(let status, _, _): return status >= 500
        case .notConfigured: return false
        }
    }
}

/// What the companion was doing when a request failed, for the words on the card.
public enum CoachAction: Sendable { case saveCard, voiceReply }

extension CoachError {
    /// The one mapping from an error to the card's words: plain, never a status code.
    public func plainMessage(for action: CoachAction) -> String {
        switch (self, action) {
        case (.server(401, _, _), _): "The coach refused the connector key."
        case (.server(429, _, let message), _): "\(message) Try again later."
        case (.server(413, _, _), .voiceReply): "That was too long. Keep an answer under a minute."
        case (.server(400, _, let message), .voiceReply): "The coach couldn't use that recording: \(message)"
        case (.server(503, "reply_unconfigured", _), .voiceReply): "Voice replies are not set up on this coach yet."
        case (.server(let status, _, _), .saveCard) where status >= 500: "The coach couldn't save this just now. Try again."
        case (.server(let status, _, _), .voiceReply) where status >= 500: "The coach couldn't reply just now. Try again."
        case (.server(_, _, let message), _): message
        default: localizedDescription
        }
    }
}

/// Talks to the shared coaching backend. Ported from the watch app's API client.
/// The Mac keeps no coaching state of its own: it reads the same fresh overview every device reads.
public struct CoachAPI: Sendable {
    public let baseURL: URL
    private let token: String
    let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    /// For the live socket's upgrade request, which goes to the same host.
    var authorizationHeader: String { "Bearer \(token)" }

    public static let defaultBaseURL = URL(string: "https://kaungzinhein113--synthetic-coaching-connector-web.us-east.modal.run")!

    func request(_ path: String, method: String = "GET", timeout: TimeInterval = 45) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            let code = (error as? URLError)?.code
            throw CoachError.offline(code == .timedOut ? "The coach took too long to answer." : "The coach can't be reached. Check the network.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            throw CoachError.server(status, body?.error ?? "error", body?.message ?? "Request failed")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func overview() async throws -> Overview {
        try await send(request("v1/overview"), as: Overview.self)
    }

    public func goalContext(_ goalID: String) async throws -> GoalContext {
        try await send(request("v1/goals/\(goalID)/context"), as: GoalContext.self)
    }

    /// One capture. Keep `idempotencyKey` for retries: a retry returns the original receipt and never pays twice.
    public func postScreenContext(_ payload: ScreenContextPayload, idempotencyKey: String) async throws -> ScreenContextReceipt {
        var request = request("v1/screen-contexts", method: "POST", timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try payload.encoded()
        return try await send(request, as: ScreenContextReceipt.self)
    }

    /// Undo hides the card from every device. It stays restorable on the server.
    public func hideScreenContext(id: String, expectedVersion: Int, idempotencyKey: String) async throws -> UndoReceipt {
        var request = request("v1/screen-contexts/\(id)", method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expected_version": expectedVersion, "deleted": true, "correction_reason": "Undone from the Mac companion."])
        return try await send(request, as: UndoReceipt.self)
    }

    public static func newIdempotencyKey(prefix: String = "mac") -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
