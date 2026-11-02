import Foundation

/// What leaves the Mac for one capture: redacted text and a few labels. No image fields exist.
public struct ScreenContextPayload: Codable, Sendable, Equatable {
    public static let maxTextCharacters = 6000
    public static let maxTextBytes = 12 * 1024
    public static let maxBodyBytes = 16 * 1024

    public enum Purpose: String, Codable, CaseIterable, Sendable { case meeting_prep, draft_check, reading }

    public struct Redaction: Codable, Sendable, Equatable {
        public let method: String
        public let counts: [String: Int]
    }

    public let goal_id: String?
    public let language: String
    public let capture_device: String
    public let purpose: Purpose
    public let occurred_at: String
    public let app_name: String?
    public let text: String
    public let redaction: Redaction

    /// Builds a payload, trimming the text to the server's limits. Returns nil when no text is left.
    public static func make(redacted: RedactionResult, appName: String?, goalID: String?, purpose: Purpose,
                            language: String = "en", occurredAt: Date = Date()) -> ScreenContextPayload? {
        let text = trim(redacted.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return nil }
        let name = appName.map { String($0.filter { !$0.isNewline && $0.asciiValue.map { $0 >= 32 && $0 != 127 } ?? true }.prefix(80)) }
        var counts: [String: Int] = [:]
        for kind in RedactionKind.allCases { counts[kind.rawValue] = redacted.counts[kind] ?? 0 }
        let formatter = ISO8601DateFormatter()
        return ScreenContextPayload(goal_id: goalID, language: language, capture_device: "mac", purpose: purpose,
                                    occurred_at: formatter.string(from: occurredAt), app_name: name?.isEmpty == false ? name : nil,
                                    text: text, redaction: Redaction(method: Redactor.method, counts: counts))
    }

    /// Cuts at a line or word boundary so the text fits both the character and the byte cap.
    static func trim(_ text: String) -> String {
        guard text.count > maxTextCharacters || text.utf8.count > maxTextBytes else { return text }
        var cut = String(text.prefix(maxTextCharacters))
        while cut.utf8.count > maxTextBytes { cut = String(cut.dropLast(max(1, (cut.utf8.count - maxTextBytes) / 3))) }
        if let boundary = cut.lastIndex(where: { $0 == "\n" || $0 == " " }), cut.distance(from: cut.startIndex, to: boundary) > cut.count / 2 {
            cut = String(cut[..<boundary])
        }
        return cut
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
