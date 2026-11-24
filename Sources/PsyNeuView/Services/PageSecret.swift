import Foundation
import Security

/// The AI assistant's page secret (PsyNeuView#381).
///
/// PsyNeuView's assistant routes (settings and consent, the key, the MCP
/// setup and token, accepting proposals, approving assistant-written code)
/// accept a request only when it carries this launch's secret in the
/// `X-PsyNeuView-Session` header. No HTTP route serves the secret, so a
/// program on this Mac that can send requests to the backend (`curl`,
/// another app, Claude Code's own shell when Claude is connected over MCP)
/// can't act as the page. The app is the channel that hands it over:
///
/// 1. **Made at launch.** 32 random bytes from the system's generator, as
///    URL-safe base64, once per app launch (`current`). Every backend start
///    in this launch and every window use the same one.
/// 2. **To the backend through a file, not the environment.** Before each
///    backend start the app writes the secret to a new file that only this
///    user can read (0600, in a 0700 folder) and names it in
///    `PSYNEUVIEW_PAGE_SECRET_FILE`. The backend reads it once and deletes
///    it. Another program running as the user can read a process's
///    environment (`ps eww`), so the secret isn't put there. Developer mode
///    starts the backend with `--reload`, whose restarts would find the file
///    gone, so there it goes in `PSYNEUVIEW_PAGE_SECRET` instead; developer
///    mode is for development, not for trying the assistant.
/// 3. **To the page with a user script**, at document start, main frame
///    only, which writes it into `sessionStorage` under `storageKey` when
///    the page's origin is the backend's. The page sends it from there.
///
/// Pure functions, so they are tested without a web view or a backend.
enum PageSecret {
    /// The page's key (PsyNeuView `frontend/src/utils/pageSecret.ts`).
    static let storageKey = "psyneuview.pageSecret"
    /// The backend reads the file this names once, then deletes it.
    static let fileVariable = "PSYNEUVIEW_PAGE_SECRET_FILE"
    /// The secret itself, for developer mode's `--reload` only.
    static let valueVariable = "PSYNEUVIEW_PAGE_SECRET"

    /// This launch's secret.
    static let current: String = make()

    /// 32 random bytes as URL-safe base64 without padding (43 characters).
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // The system generator failing is not expected; fall back to the
            // standard library's, which is also cryptographically secure.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The folder the files go in: the user's own temporary folder, in a
    /// subfolder only the user can open.
    static func defaultDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("psyneuview-page-secret", isDirectory: true)
    }

    /// Write `secret` to a new file only this user can read, in `directory`
    /// (made 0700 if missing), and return it. A new name each time, so a
    /// backend start never reads a file left from an earlier one.
    static func writeFile(_ secret: String, in directory: URL = defaultDirectory()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(UUID().uuidString)
        // Created 0600 before anything is written, so it is never readable by others.
        guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(secret.utf8))
        return file
    }

    /// The variables that hand `secret` to the backend: a file normally,
    /// the value itself when the backend runs with `--reload`.
    static func backendVariables(secret: String, reload: Bool,
                                 directory: URL = defaultDirectory()) throws -> [String: String] {
        if reload {
            return [valueVariable: secret]
        }
        return [fileVariable: try writeFile(secret, in: directory).path]
    }

    /// `scheme://host:port` of `url`, as `location.origin` spells it; nil
    /// for anything but http and https.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "http" ? 80 : 443
        if let port = url.port, port != defaultPort {
            return "\(scheme)://\(shownHost):\(port)"
        }
        return "\(scheme)://\(shownHost)"
    }

    /// The user script: writes `secret` into `sessionStorage` when the page
    /// is at `origin`, and nowhere else.
    static func userScript(secret: String, origin: String) -> String {
        """
        (function () {
          try {
            if (window.location.origin !== \(jsString(origin))) return;
            window.sessionStorage.setItem(\(jsString(storageKey)), \(jsString(secret)));
          } catch (e) {}
        })();
        """
    }

    /// A JavaScript string literal for `text` (JSON's quoting is valid JavaScript).
    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
