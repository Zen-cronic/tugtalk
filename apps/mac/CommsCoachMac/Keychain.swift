import Foundation
import ScreenContextCore
import Security

/// Where the companion gets its backend and key. The key lives in the login Keychain, never in
/// the app bundle, UserDefaults or logs. Add it once with:
///   security add-generic-password -s com.kaungzinhein.commscoach.mac -a connector -w
enum Connection {
    enum Source: Equatable { case keychain, localDevelopment }

    /// The API client, or nil when no key is configured yet or the configured address is refused.
    static func api() -> (api: CoachAPI, source: Source)? {
        if isLocalDevelopmentRequested { return localDevelopment().map { ($0, .localDevelopment) } }
        // The Keychain key goes only to the configured coach host over HTTPS (see BaseURLPolicy).
        guard let base = BaseURLPolicy.keychainBaseURL(Settings.baseURL), let token = keychainToken() else { return nil }
        return (CoachAPI(baseURL: base, token: token), .keychain)
    }

    /// Why `api()` returned nil, in words for the bubble and the menu.
    static var unavailableReason: String {
        if isLocalDevelopmentRequested { return "The local test server settings are not usable." }
        if BaseURLPolicy.keychainBaseURL(Settings.baseURL) == nil { return "The coach address must be \(CoachAPI.defaultBaseURL.absoluteString)." }
        return CoachError.notConfigured.localizedDescription
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
        guard let base = BaseURLPolicy.localDevelopmentBaseURL(defaults.string(forKey: "devBaseURL").flatMap(URL.init(string:))),
              let file = defaults.string(forKey: "devTokenFile") else { return nil }
        guard let token = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return CoachAPI(baseURL: base, token: token)
    }

    static var isLocalDevelopmentRequested: Bool { UserDefaults.standard.string(forKey: "devBaseURL") != nil }
}
