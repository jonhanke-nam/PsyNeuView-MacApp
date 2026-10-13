import Foundation

/// GitHub's device flow for a **GitHub App**, implemented natively.
///
/// The app previously installed the `gh` CLI machine-wide purely to authenticate
/// and clone, then drove `gh auth login --web` as a subprocess and scraped its
/// stdout for the one-time code. Doing the flow directly removes a global install
/// and lets the app hold its own credential instead of borrowing whichever
/// account happens to be active in the user's `gh` session. (#63, under #26)
///
/// A GitHub App rather than an OAuth App, deliberately. An OAuth App cannot be
/// scoped below "every private repository the user can reach"; a GitHub App is
/// installed per repository, and `repositoryID` narrows the token further to a
/// single repo. It also issues short-lived tokens — and because the grant came
/// from the device flow, refreshing needs no client secret, which is what makes
/// this viable in a desktop app at all.
///
/// Reference:
/// https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
enum GitHubDeviceFlow {

    // MARK: - Configuration

    /// Client ID of the PsyNeuView GitHub App — the value beginning `Iv23li…`,
    /// which is *not* the App ID.
    ///
    /// Public by design — the device flow is built for clients that cannot keep
    /// a secret, which is why no client secret ships with this app.
    static let clientID = "Iv23liEJai2R0egqpdGM"

    /// Restrict issued tokens to `jonhanke-nam/PsyNeuView` and nothing else.
    /// Even a user whose account can reach other repositories gets a token that
    /// cannot touch them.
    static let repositoryID = "1204522752"

    /// Refresh this far ahead of expiry, so a long clone can't have the token
    /// expire underneath it.
    static let refreshSkew: TimeInterval = 5 * 60

    static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    // MARK: - Types

    /// What GitHub returns when a device flow starts.
    struct DeviceCode: Sendable, Equatable {
        /// Shown to the user; they type it into the browser.
        let userCode: String
        /// Used by us when polling; never shown.
        let deviceCode: String
        /// Where the user enters the code.
        let verificationURI: URL
        /// Seconds to wait between polls.
        let interval: TimeInterval
        /// Seconds until `deviceCode` expires.
        let expiresIn: TimeInterval
    }

    /// An issued credential. GitHub App user tokens (`ghu_…`) last 8 hours and
    /// come with a refresh token (`ghr_…`) good for six months.
    ///
    /// Both expiries are absolute instants, not durations, because this is
    /// persisted and read back long after it was issued.
    struct TokenGrant: Sendable, Equatable, Codable {
        let accessToken: String
        let expiresAt: Date
        /// Absent when the app has "expire user authorization tokens" turned off.
        let refreshToken: String?
        let refreshTokenExpiresAt: Date?

        /// Usable now, allowing for the refresh skew.
        func isFresh(at now: Date = Date(), skew: TimeInterval = refreshSkew) -> Bool {
            now.addingTimeInterval(skew) < expiresAt
        }

        /// A refresh is still possible.
        func canRefresh(at now: Date = Date()) -> Bool {
            guard refreshToken != nil else { return false }
            guard let refreshExpiry = refreshTokenExpiresAt else { return true }
            return now < refreshExpiry
        }
    }

    /// One poll's outcome.
    enum PollOutcome: Sendable, Equatable {
        /// Authorised — here is the credential.
        case authorized(TokenGrant)
        /// The user hasn't finished yet; keep polling at the current interval.
        case pending
        /// We polled too fast; wait this much longer between polls.
        case slowDown(newInterval: TimeInterval)
        /// Terminal failure, with a message fit to show a person.
        case failed(reason: String)
    }

    enum FlowError: LocalizedError, Equatable {
        case notConfigured
        case badResponse(String)
        case timedOut
        case refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return """
                    GitHub sign-in isn't configured in this build.

                    PsyNeuView needs a GitHub App client ID with device flow \
                    enabled. Register the app, install it on the PsyNeuView \
                    repository, and set GitHubDeviceFlow.clientID.
                    """
            case .badResponse(let detail):
                return "GitHub returned an unexpected response: \(detail)"
            case .timedOut:
                return "The sign-in code expired before it was entered. Try again."
            case .refreshFailed(let detail):
                return "Couldn't renew GitHub access: \(detail)"
            }
        }
    }

    // MARK: - Parsing (pure, unit-testable)

    /// Parse the JSON body of a `POST /login/device/code` response.
    static func parseDeviceCode(_ data: Data) throws -> DeviceCode {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError.badResponse("body was not JSON")
        }
        if let error = object["error"] as? String {
            throw FlowError.badResponse(describe(error: error, description: object["error_description"] as? String))
        }
        guard let userCode = object["user_code"] as? String,
              let deviceCode = object["device_code"] as? String,
              let uriString = object["verification_uri"] as? String,
              let uri = URL(string: uriString) else {
            throw FlowError.badResponse("missing device-flow fields")
        }
        return DeviceCode(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURI: uri,
            interval: numeric(object["interval"]) ?? 5,
            expiresIn: numeric(object["expires_in"]) ?? 900
        )
    }

    /// Interpret one `POST /login/oauth/access_token` response.
    ///
    /// The device flow signals progress through `error` codes rather than HTTP
    /// status, so a 200 carrying `authorization_pending` is the normal case while
    /// the user is still typing.
    static func parsePollOutcome(
        _ data: Data,
        currentInterval: TimeInterval,
        now: Date = Date()
    ) -> PollOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(reason: "GitHub returned a response that wasn't JSON.")
        }
        if let grant = parseGrant(object, now: now) {
            return .authorized(grant)
        }
        let description = object["error_description"] as? String
        switch object["error"] as? String {
        case "authorization_pending":
            return .pending
        case "slow_down":
            // GitHub asks for +5s, but honours an explicit interval when present.
            return .slowDown(newInterval: numeric(object["interval"]) ?? currentInterval + 5)
        case .some(let code):
            return .failed(reason: describe(error: code, description: description))
        case nil:
            return .failed(reason: "GitHub returned no token and no error.")
        }
    }

    /// Build a `TokenGrant` from a token response body, or nil if there isn't one.
    static func parseGrant(_ object: [String: Any], now: Date = Date()) -> TokenGrant? {
        guard let token = object["access_token"] as? String, !token.isEmpty else { return nil }
        // A GitHub App with token expiry disabled omits expires_in entirely; treat
        // that as a long-lived token rather than one that expired on arrival.
        let lifetime = numeric(object["expires_in"]) ?? (60 * 60 * 24 * 365)
        let refreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let refreshLifetime = numeric(object["refresh_token_expires_in"])
        return TokenGrant(
            accessToken: token,
            expiresAt: now.addingTimeInterval(lifetime),
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshLifetime.map { now.addingTimeInterval($0) }
        )
    }

    /// Turn a GitHub error code into something a person can act on.
    static func describe(error code: String, description: String?) -> String {
        switch code {
        case "expired_token":
            return "The sign-in code expired. Start setup again to get a new one."
        case "access_denied":
            return "Sign-in was cancelled in the browser."
        case "incorrect_device_code":
            return "That sign-in code wasn't recognised. Start setup again."
        case "device_flow_disabled":
            return "Device flow isn't enabled on the PsyNeuView GitHub App. "
                + "Enable it in the app's settings, then try again."
        case "incorrect_client_credentials":
            return "The GitHub App client ID in this build isn't valid."
        case "unsupported_grant_type":
            return "GitHub rejected the sign-in request type. This is a bug in PsyNeuView."
        default:
            return description ?? "GitHub reported: \(code)"
        }
    }

    /// Accept either a JSON number or a numeric string.
    private static func numeric(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return TimeInterval(text) }
        return nil
    }

    // MARK: - Network

    /// Begin a device flow: ask GitHub for a code to show the user.
    ///
    /// GitHub Apps take no `scope` — a user token is limited to the intersection
    /// of the app's configured permissions and the user's own access.
    static func start(session: URLSession = .shared) async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw FlowError.notConfigured }
        let (data, _) = try await session.data(
            for: formRequest(url: deviceCodeURL, fields: ["client_id": clientID]))
        return try parseDeviceCode(data)
    }

    /// Poll once for the token.
    static func poll(
        deviceCode: String,
        currentInterval: TimeInterval,
        session: URLSession = .shared
    ) async throws -> PollOutcome {
        var fields = [
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]
        // Narrow the token to PsyNeuView alone.
        if !repositoryID.isEmpty { fields["repository_id"] = repositoryID }
        let (data, _) = try await session.data(for: formRequest(url: accessTokenURL, fields: fields))
        return parsePollOutcome(data, currentInterval: currentInterval)
    }

    /// Exchange a refresh token for a fresh grant.
    ///
    /// No `client_secret`: GitHub waives it when the original grant came from the
    /// device flow, which is precisely why a desktop app can do this at all.
    static func refresh(
        using refreshToken: String,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> TokenGrant {
        guard !clientID.isEmpty else { throw FlowError.notConfigured }
        let (data, _) = try await session.data(for: formRequest(url: accessTokenURL, fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError.refreshFailed("response wasn't JSON")
        }
        if let grant = parseGrant(object, now: now) { return grant }
        throw FlowError.refreshFailed(
            describe(error: object["error"] as? String ?? "unknown",
                     description: object["error_description"] as? String))
    }

    private static func formRequest(url: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }
}
