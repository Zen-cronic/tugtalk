import Foundation

/// Where the connector key may be sent. The key goes only to the configured coach host over HTTPS,
/// or, for local testing with a throwaway key, to this machine. Anything else is refused, so a
/// changed `baseURL` default can never send the Keychain key to another host.
public enum BaseURLPolicy {
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// The base URL for the Keychain key: HTTPS on the configured host, no user info, or nil.
    public static func keychainBaseURL(_ candidate: URL?, configured: URL = CoachAPI.defaultBaseURL) -> URL? {
        guard let candidate, candidate.scheme?.lowercased() == "https", candidate.user == nil, candidate.password == nil,
              let host = candidate.host?.lowercased(), host == configured.host?.lowercased() else { return nil }
        return candidate
    }

    /// The base URL for a local test server: HTTP or HTTPS on this machine only, or nil.
    public static func localDevelopmentBaseURL(_ candidate: URL?) -> URL? {
        guard let candidate, ["http", "https"].contains(candidate.scheme?.lowercased() ?? ""), candidate.user == nil,
              let host = candidate.host?.lowercased(), loopbackHosts.contains(host) else { return nil }
        return candidate
    }
}
