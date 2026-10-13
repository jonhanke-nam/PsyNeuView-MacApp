import Foundation
import Security

/// PsyNeuView's GitHub credential, kept in the login Keychain under the app's
/// own service name.
///
/// Previously the app had no credential of its own: it installed `gh`, let that
/// tool own the session, and skipped authentication entirely whenever
/// `gh auth status` happened to succeed — silently using whichever account was
/// active, which may not be the one with access to the PsyNeuView repo. (#63)
///
/// Stores the whole grant, not just the token, because GitHub App user tokens
/// expire after eight hours and have to be refreshed.
enum GitHubCredential {
    /// Keychain service name. Distinct from `gh`'s, so the two never collide,
    /// and per app identity, so the test app's grant is its own (#209).
    static let service = AppIdentity.current.keychainService
    static let account = "github-app-user-grant"

    // MARK: - Storage

    @discardableResult
    static func save(_ grant: GitHubDeviceFlow.TokenGrant) -> Bool {
        guard let data = try? JSONEncoder().encode(grant) else { return false }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Readable without a prompt once the user has logged in, and never
            // synced to other devices.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// The stored grant, or nil when the app has never been authorised.
    static func load() -> GitHubDeviceFlow.TokenGrant? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GitHubDeviceFlow.TokenGrant.self, from: data)
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Freshness

    /// What should happen to a stored grant before it is used.
    ///
    /// Pure, so the expiry logic is testable without a Keychain or a network.
    enum Disposition: Sendable, Equatable {
        /// Still valid — use this token.
        case usable(String)
        /// Expired or nearly so, but refreshable.
        case needsRefresh(refreshToken: String)
        /// Nothing usable; the user must authorise again.
        case needsAuthorization
    }

    static func disposition(
        of grant: GitHubDeviceFlow.TokenGrant?,
        at now: Date = Date()
    ) -> Disposition {
        guard let grant else { return .needsAuthorization }
        if grant.isFresh(at: now) { return .usable(grant.accessToken) }
        if grant.canRefresh(at: now), let refreshToken = grant.refreshToken {
            return .needsRefresh(refreshToken: refreshToken)
        }
        return .needsAuthorization
    }

    /// A token that is valid right now, refreshing and re-storing if needed.
    /// Returns nil when the user has to authorise again.
    static func validAccessToken(now: Date = Date()) async -> String? {
        switch disposition(of: load(), at: now) {
        case .usable(let token):
            return token
        case .needsRefresh(let refreshToken):
            guard let renewed = try? await GitHubDeviceFlow.refresh(using: refreshToken, now: now) else {
                // The refresh token was revoked or is no longer accepted; drop the
                // dead grant so setup asks for authorisation cleanly.
                delete()
                return nil
            }
            save(renewed)
            return renewed.accessToken
        case .needsAuthorization:
            return nil
        }
    }

    // MARK: - Git

    /// Git config that authenticates an HTTPS request with the token.
    ///
    /// Passed as `git -c <...>` *before* the subcommand, which applies it to that
    /// one invocation without writing it into the new repository's config — so
    /// the token never lands on disk in `.git/config`, the way embedding it in
    /// the remote URL would.
    static func gitAuthConfig(token: String) -> String {
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return "http.extraHeader=Authorization: Basic \(basic)"
    }

    /// Redact a token anywhere it might appear in text headed for a log.
    static func redact(_ text: String, token: String?) -> String {
        guard let token, !token.isEmpty else { return text }
        var redacted = text.replacingOccurrences(of: token, with: "••••••")
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        redacted = redacted.replacingOccurrences(of: basic, with: "••••••")
        return redacted
    }
}
