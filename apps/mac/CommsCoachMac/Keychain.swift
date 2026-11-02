import Foundation
import ScreenContextCore
import Security

/// Where the companion gets its backend and key. The key lives in the login Keychain, never in
/// the app bundle, UserDefaults or logs. Add it once with:
///   security add-generic-password -s com.zencronic.commscoach.mac -a connector -w
enum Connection {
    enum Source: Equatable { case keychain, localDevelopment }

    /// The API client, or nil when no key is configured yet.
    static func api() -> (api: CoachAPI, source: Source)? {
        if let local = localDevelopment() { return (local, .localDevelopment) }
        guard let token = keychainToken() else { return nil }
        return (CoachAPI(baseURL: Settings.baseURL, token: token), .keychain)
    }

    static func keychainToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Settings.keychainService,
                                    kSecAttrAccount as String: Settings.keychainAccount,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), token.count >= 32 else { return nil }
        return token
    }

    /// `-devBaseURL http://127.0.0.1:4319 -devTokenFile <path>`: a local test server with a throwaway
    /// token (see scripts/local-stub-server.mjs). Refused for any host other than this machine, and the
    /// Keychain is not read at all in this mode.
    static func localDevelopment() -> CoachAPI? {
        let defaults = UserDefaults.standard
        guard let base = defaults.string(forKey: "devBaseURL").flatMap(URL.init(string:)), let file = defaults.string(forKey: "devTokenFile") else { return nil }
        guard let host = base.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        guard let token = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return CoachAPI(baseURL: base, token: token)
    }

    static var isLocalDevelopmentRequested: Bool { UserDefaults.standard.string(forKey: "devBaseURL") != nil }
}
