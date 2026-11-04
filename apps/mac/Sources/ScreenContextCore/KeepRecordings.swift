import Foundation

// "Keep my recordings": the person's opt-in setting on the coach server (GET and PATCH /v1/settings), off by default.
// Off, the server deletes audio after transcription. On, it keeps each recording's original WAV in the account,
// where the person can see, download and delete it (/v1/media).

/// What the account keeps, as the server counts it.
public struct KeptCounts: Decodable, Sendable, Equatable {
    public let recordings: Int
    public let bytes: Int
    public let cap_bytes: Int
}

public struct CoachSettings: Decodable, Sendable, Equatable {
    public let keep_recordings: Bool
    public let version: Int
    public let kept: KeptCounts?
}

/// The `media` block on a saved recording or voice round. Absent when the setting is off.
public struct KeptMedia: Decodable, Sendable, Equatable {
    public let kept: Bool
    public let bytes: Int?
    public let sha256: String?
    public let reason: String?
    public let message: String?

    /// The line a result card shows, or nil when there is nothing to say.
    public var note: String? {
        if kept { return KeepRecordingsCopy.kept }
        if reason == "full" { return KeepRecordingsCopy.notKeptFull }
        return nil
    }
}

/// One kept recording in the account's list. No audio.
public struct KeptRecording: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let record_kind: String
    public let bytes: Int
    public let occurred_at: String?
}

/// The plain words, in one place, so the watch and the Mac say the same thing.
public enum KeepRecordingsCopy {
    public static let label = "Keep my recordings"
    public static let menuLabel = "Keep My Recordings"
    public static let explainerOff = "Off: audio is deleted after transcription."
    public static let explainerOn = "On: your recordings stay in your account. Delete them any time."
    public static let kept = "Recording kept"
    public static let notKeptFull = "Recording not kept: storage full"
    public static let turnOff = "Turn Off"
    public static let turnOffAndDelete = "Turn Off and Delete Kept Recordings"

    /// "3 kept, 1.2 MB".
    public static func summary(_ counts: KeptCounts) -> String {
        "\(counts.recordings) kept, \(size(counts.bytes))"
    }

    public static func size(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", mb)
    }
}

private struct SettingsBody: Decodable { let settings: CoachSettings }
private struct MediaListBody: Decodable { let media: [KeptRecording] }

extension CoachAPI {
    public func settings() async throws -> CoachSettings {
        try await send(request("v1/settings"), as: SettingsBody.self).settings
    }

    /// The PATCH body. `deleteKept` is sent only when turning the setting off.
    public static func settingsPatch(keep: Bool, deleteKept: Bool, expectedVersion: Int) throws -> Data {
        var body: [String: Any] = ["expected_version": expectedVersion, "keep_recordings": keep]
        if !keep && deleteKept { body["delete_kept_recordings"] = true }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Turns the setting on or off. Keep `idempotencyKey` for a retry. Returns the settings as saved.
    public func setKeepRecordings(_ keep: Bool, deleteKept: Bool = false, expectedVersion: Int, idempotencyKey: String) async throws -> CoachSettings {
        var request = request("v1/settings", method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try Self.settingsPatch(keep: keep, deleteKept: deleteKept, expectedVersion: expectedVersion)
        return try await send(request, as: SettingsBody.self).settings
    }

    public func keptRecordings() async throws -> [KeptRecording] {
        try await send(request("v1/media"), as: MediaListBody.self).media
    }

    /// The WAV of one kept recording. Only its owner can download it.
    public func downloadKeptRecording(id: String) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request("v1/media/\(id)")) } catch {
            throw CoachError.offline("The coach can't be reached. Check the network.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CoachError.server(status, "download_failed", "The recording could not be downloaded.") }
        return data
    }

    public func deleteAllKeptRecordings(idempotencyKey: String) async throws {
        var request = request("v1/media", method: "DELETE")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        _ = try await send(request, as: UndoReceipt.self)
    }
}
