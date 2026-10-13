import Foundation

/// The `pnvFile` bridge between PsyNeuView's page and the Mac's filesystem
/// (#28; `reveal` for jonhanke-nam/PsyNeuView-archive#1295).
///
/// The page needs real absolute paths (the backend works on paths on disk),
/// which `<input type="file">` can never give it inside WKWebView, and it
/// cannot open Finder itself. The frontend capability-detects
/// `window.webkit.messageHandlers.pnvFile` and falls back to typed-path
/// prompts on plain web. Same pattern as `pnvSettings` (`SettingsBridge`).
///
/// JS contract (frontend half: jonhanke-nam/PsyNeuView-archive#347, #1295).
/// `postMessage` returns a Promise; a malformed or unknown message rejects it.
///
///     { op: "open", directories?: bool, extensions?: [string],
///                   message?: string, defaultDir?: string }  -> { path }
///     { op: "saveAs", defaultName?: string, extensions?: [string],
///                     message?: string, defaultDir?: string } -> { path }
///         path: string | null   (null = the user cancelled)
///
///     { op: "reveal", path: string }                          -> { revealed: true }
///         Shows the file or folder in Finder, selected in its parent folder
///         (what "Show in Finder" does). A leading `~` is the home folder;
///         the path is normalized (`..`, `.`, doubled and trailing slashes).
///         Rejects when `path` is missing or empty
///             ("pnvFile: 'reveal' needs a 'path'"),
///         or when nothing is there
///             ("There's no folder or file at ~/the/path.").
///         Apps older than this op reject it as an unknown op; the page
///         treats any reply without `revealed: true` as "not supported" and
///         hides or disables its Show in Finder button, so the app side
///         needs no version check.
///
/// The panels for `open` and `saveAs` are UI and live with the web view
/// (`AppWindowView.Coordinator`). The decisions — what the message asked
/// for, whether it can be done, what to answer — are here as pure functions,
/// so they can be tested without a web view or a Finder.
enum FileBridge {
    static let handlerName = "pnvFile"

    struct Failure: Error, Equatable {
        let message: String
    }

    /// What `reveal` decided: the reply, and the item to show in Finder when
    /// the reply is a success.
    struct RevealOutcome {
        var reply: Result<[String: Any], Failure>
        /// Select this in its parent folder, then send the reply.
        var reveal: URL? = nil
    }

    /// The reply a successful `reveal` sends; the page keys off this exact
    /// field, so don't rename it. (Computed: a `[String: Any]` isn't
    /// Sendable, so it can't be a global `let` under strict concurrency.)
    static var revealedReply: [String: Any] { ["revealed": true] }

    /// `{ op: "reveal", path }`. `exists` answers whether anything is at a
    /// normalized absolute path; the app passes `FileManager`, tests a stub.
    static func handleReveal(
        body: [String: Any], exists: (String) -> Bool
    ) -> RevealOutcome {
        guard let raw = body["path"] as? String else {
            return fail("pnvFile: 'reveal' needs a 'path'")
        }
        let path = normalizedPath(raw)
        guard !path.isEmpty else {
            return fail("pnvFile: 'reveal' needs a 'path'")
        }
        // A path relative to the app's working directory is never what the
        // page meant; say so instead of reporting it missing from somewhere
        // the user can't see.
        guard path.hasPrefix("/") else {
            return fail("pnvFile: 'reveal' needs an absolute path, not '\(raw)'")
        }
        guard exists(path) else {
            return fail("There's no folder or file at \(abbreviated(path)).")
        }
        return RevealOutcome(
            reply: .success(revealedReply),
            reveal: URL(fileURLWithPath: path))
    }

    /// Trimmed, `~` expanded, and standardized (`..`, `.`, doubled and
    /// trailing slashes resolved). Empty stays empty.
    static func normalizedPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// The home folder written as `~`, as the user would type it.
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static func fail(_ message: String) -> RevealOutcome {
        RevealOutcome(reply: .failure(Failure(message: message)))
    }
}
