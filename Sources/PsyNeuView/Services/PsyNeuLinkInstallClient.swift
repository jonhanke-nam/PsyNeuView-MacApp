import Foundation

/// Talks to the backend's PsyNeuLink install API (#132).
///
/// The Mac app is a conduit for this setting, not a second implementation. The
/// backend already owns source selection, the install job, its progress and its
/// result — `POST /settings/install` and friends — and the gear icon in the web
/// UI drives exactly these endpoints.
///
/// Previously the app kept its own copy of the choice in `UserDefaults` and
/// built its own pip arguments in `Updater`. That made three records of one
/// fact (the app's, pip's, and the env vars passed to uvicorn for display) and
/// meant a change made in one window would be reverted by the other.
///
/// This type exists so ⌘, Preferences can present the same operation rather
/// than reproduce it.
enum PsyNeuLinkInstallClient {

    enum Source: String, Codable {
        case pypi, github, local
    }

    struct Capabilities: Decodable {
        let enabled: Bool
        let reason: String?
        let in_mac_app: Bool
        let mode: String
    }

    /// What the backend reports is installed right now.
    ///
    /// This is the answer to "which PsyNeuLink?", and it is the backend's to
    /// give: it introspects the package and, for an editable install, reads git
    /// from the folder it points at. The app asking here rather than consulting
    /// its own stored copy is the whole point of #132.
    struct Current: Decodable {
        let version: String?
        let source: String?
        let branch: String?
        let repo: String?
        let path: String?
        /// The commit the installed build was made from, when the backend knows
        /// it. Used to tell whether a reinstall would change anything (#153).
        let commit: String?

        /// The install source, when it is one we can act on.
        var installSource: Source? {
            switch source {
            case "pypi": return .pypi
            case "github": return .github
            case "local", "editable": return .local
            default: return nil
            }
        }
    }

    private struct SettingsInfo: Decodable {
        let psyneulink: Current
    }

    struct Job: Decodable {
        let id: String
        let source: String
        let ref: String?
        let path: String?
        let repo: String?
        let status: String
        let log: [String]
        let exit_code: Int?

        /// The backend's terminal states. Anything else means still running.
        var isFinished: Bool { status == "succeeded" || status == "failed" }
        var succeeded: Bool { status == "succeeded" }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Requests

    static func capabilities(port: Int, session: URLSession = .shared) async throws -> Capabilities {
        try await get("settings/install/capabilities", port: port, session: session)
    }

    /// Start an install. Returns the job to poll.
    ///
    /// `ref` is the branch, tag or commit for `github`; `path` the folder for
    /// `local`; `repo` an `owner/name` override. The backend validates the
    /// combination — deliberately not re-checked here, so there is one set of
    /// rules and one set of messages.
    static func startInstall(
        source: Source,
        ref: String? = nil,
        path: String? = nil,
        repo: String? = nil,
        port: Int,
        session: URLSession = .shared
    ) async throws -> Job {
        var body: [String: Any] = ["source": source.rawValue]
        if let ref, !ref.isEmpty { body["ref"] = ref }
        if let path, !path.isEmpty { body["path"] = path }
        if let repo, !repo.isEmpty { body["repo"] = repo }

        var request = URLRequest(url: try url("settings/install", port: port))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
        return try JSONDecoder().decode(Job.self, from: data)
    }

    /// What is installed now, per the backend.
    static func current(port: Int, session: URLSession = .shared) async throws -> Current {
        let info: SettingsInfo = try await get("settings/info", port: port, session: session)
        return info.psyneulink
    }

    static func job(id: String, port: Int, session: URLSession = .shared) async throws -> Job {
        try await get("settings/install/\(id)", port: port, session: session)
    }

    // MARK: - Plumbing

    private static func url(_ path: String, port: Int) throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/\(path)") else {
            throw Failure(message: "Could not build a URL for \(path)")
        }
        return url
    }

    private static func get<T: Decodable>(
        _ path: String, port: Int, session: URLSession
    ) async throws -> T {
        let (data, response) = try await session.data(from: try url(path, port: port))
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Surface the backend's own message rather than a status code.
    ///
    /// These endpoints answer refusals with an explanation — why install is
    /// unavailable, which combination of arguments is wrong — and that text is
    /// what the user needs to see. A bare "409" is not.
    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] as? String {
            throw Failure(message: detail)
        }
        throw Failure(message: "The backend returned \(http.statusCode).")
    }
}
