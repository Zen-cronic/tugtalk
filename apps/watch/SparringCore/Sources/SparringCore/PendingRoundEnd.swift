import Foundation

/// The round end the watch owes the server, kept across practice screens. Each screen has its own `SparringMachine`,
/// so without this an end that failed (the watch was offline when the screen closed) was lost with the screen and
/// the server kept counting the old round. The next screen inherits it and sends it, with the same key, before its
/// first answer.
///
/// An end older than `maxAge` is dropped: by then the server's own 15-minute round window has closed that round, and
/// a late end would only cut short a round started since on another device.
public struct PendingRoundEndStore {
    public static let maxAge: TimeInterval = 15 * 60
    private static let keyName = "pendingRoundEnd.key", atName = "pendingRoundEnd.at"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The key still owed, or nil (none, or too old to send).
    public func load(now: Date) -> String? {
        guard let key = defaults.string(forKey: Self.keyName) else { return nil }
        let at = defaults.double(forKey: Self.atName)
        guard at > 0, now.timeIntervalSince1970 - at <= Self.maxAge else { clear(); return nil }
        return key
    }

    /// An end is on its way with this key. The first time it was owed is kept, so resends do not extend its life.
    public func save(_ key: String, at now: Date) {
        if defaults.string(forKey: Self.keyName) == key { return }
        defaults.set(key, forKey: Self.keyName)
        defaults.set(now.timeIntervalSince1970, forKey: Self.atName)
    }

    /// The server confirmed the end sent with this key.
    public func confirmed(_ key: String) {
        if defaults.string(forKey: Self.keyName) == key { clear() }
    }

    private func clear() {
        defaults.removeObject(forKey: Self.keyName)
        defaults.removeObject(forKey: Self.atName)
    }
}
