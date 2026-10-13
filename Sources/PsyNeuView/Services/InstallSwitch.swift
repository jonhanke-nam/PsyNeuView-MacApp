import Foundation

/// Which PsyNeuView the app runs, and switching between them in place (#195).
///
/// There are two kinds of install. The one **included with this app** is
/// unpacked to `…/Application Support/PsyNeuView/psyneuview-<version>` and
/// follows the app's own updates (#186). A **checkout** is someone's own
/// PsyNeuView folder — a git clone they work in, with a Makefile.
///
/// Settings used to offer only a path field, so there was no way back to the
/// included version short of typing its hidden folder. "Reset Setup" (#187)
/// tried to fix that by forgetting the install and rerunning the wizard, which
/// was the wrong model: the need is to switch, and nothing should be forgotten
/// or deleted to do it. Switching back is the same action.
///
/// The rules are pure functions over `Facts`, so they can be tested without
/// touching a disk; `facts(at:)` is the one place that reads one.
enum InstallSwitch {

    /// What the user picked in Settings.
    enum Choice: Equatable, Hashable {
        /// The PsyNeuView this app carries, whatever version that is.
        case bundled
        /// A PsyNeuView checkout at this path.
        case checkout(String)
    }

    /// What is on disk at a folder, read once by `facts(at:)`.
    struct Facts: Equatable {
        var exists: Bool
        var hasGitDir: Bool
        var hasMakefile: Bool
        var hasBackend: Bool
        var hasBuiltFrontend: Bool
        /// The version stamped in BUNDLED_VERSION, which only an install made
        /// from the app's archive carries.
        var stampedVersion: String?

        static let missing = Facts(
            exists: false, hasGitDir: false, hasMakefile: false,
            hasBackend: false, hasBuiltFrontend: false, stampedVersion: nil)
    }

    /// What kind of install a folder holds.
    enum Kind: Equatable {
        case bundled(version: String?)
        case checkout
    }

    /// A clone has `.git` and a Makefile; an install unpacked from the app's
    /// archive deliberately has neither (#89). Either one marks a checkout, so
    /// a downloaded-zip checkout without `.git` still counts as one and is
    /// never "moved" to the included version at launch (#186).
    static func kind(of facts: Facts) -> Kind {
        if facts.hasGitDir || facts.hasMakefile { return .checkout }
        return .bundled(version: facts.stampedVersion)
    }

    /// The outcome of pressing Apply & Restart.
    enum Decision: Equatable {
        /// Already running what was picked.
        case nothingToDo
        /// Unpack (if needed) and run the version included with the app.
        case useBundled(version: String)
        /// Run the checkout at this path.
        case useCheckout(path: String)
        /// Can't switch, and why, in words for the user.
        case refuse(String)
    }

    /// Decide what Apply & Restart does.
    ///
    /// - Parameters:
    ///   - choice: what the user picked.
    ///   - currentPath: the folder in use now, if any.
    ///   - current: what is in that folder.
    ///   - archiveVersion: the version of PsyNeuView inside this app, if any.
    ///   - target: for a checkout choice, what is in the chosen folder.
    static func decide(
        choice: Choice,
        currentPath: String?,
        current: Facts?,
        archiveVersion: String?,
        target: Facts?
    ) -> Decision {
        switch choice {
        case .bundled:
            guard let archiveVersion else {
                return .refuse(
                    "This copy of the app doesn't include PsyNeuView, so there is "
                    + "nothing to switch to. Choose a checkout instead.")
            }
            if let current, case .bundled(let version) = kind(of: current),
               version == archiveVersion, current.exists {
                return .nothingToDo
            }
            return .useBundled(version: archiveVersion)

        case .checkout(let raw):
            let path = normalized(raw)
            guard !path.isEmpty else {
                return .refuse("Choose the folder of your PsyNeuView checkout.")
            }
            let facts = target ?? .missing
            guard facts.exists else {
                return .refuse("There is no folder at \(path).")
            }
            if kind(of: facts) != .checkout {
                if facts.stampedVersion != nil {
                    return .refuse(
                        "That folder is a copy this app unpacked, not a checkout. "
                        + "Choose “Included with this app” instead.")
                }
                return .refuse(
                    "That folder isn't a PsyNeuView checkout: expected a Makefile "
                    + "and a backend folder inside it.")
            }
            guard facts.hasBackend else {
                return .refuse(
                    "That folder isn't a PsyNeuView checkout: it has no backend folder.")
            }
            // The app serves the built frontend; it doesn't build one. A fresh
            // clone would otherwise switch, then fail to start for a reason
            // only the log explains.
            guard facts.hasBuiltFrontend else {
                return .refuse(
                    "That checkout's frontend hasn't been built yet (no "
                    + "frontend/dist). Run “npm run build” in its frontend "
                    + "folder, then switch.")
            }
            if let currentPath, normalized(currentPath) == path {
                return .nothingToDo
            }
            return .useCheckout(path: path)
        }
    }

    /// What the radio buttons should start on for the folder in use.
    static func choice(currentPath: String?, current: Facts?) -> Choice {
        guard let currentPath, let current else { return .bundled }
        switch kind(of: current) {
        case .bundled: return .bundled
        case .checkout: return .checkout(normalized(currentPath))
        }
    }

    /// Trim whitespace and a trailing slash, so `/a/b/` and `/a/b` are one
    /// folder.
    static func normalized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: - Remembered checkouts

    /// Checkouts used before, most recent first, like PsyNeuLink sources in
    /// PsyNeuView-archive#1276. Adding one moves it to the front; the list is capped.
    static func remembering(_ path: String, in list: [String], limit: Int = 6) -> [String] {
        let path = normalized(path)
        guard !path.isEmpty else { return list }
        let rest = list.map(normalized).filter { $0 != path && !$0.isEmpty }
        return Array(([path] + rest).prefix(limit))
    }

    // MARK: - Saying which install is running

    /// The branch a checkout is on, from the contents of its `.git/HEAD`.
    /// `ref: refs/heads/devel` -> `devel`; a detached HEAD -> its short hash.
    static func branch(fromHEAD contents: String) -> String? {
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            let name = ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
            return name.isEmpty ? nil : name
        }
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7))
    }

    /// One plain line saying which PsyNeuView is running, for Settings, About
    /// and the log: "PsyNeuView 0.5.8, included with this app" or "Your
    /// PsyNeuView checkout at ~/code/PsyNeuView, on branch devel".
    static func describe(
        path: String?, facts: Facts?, branch: String?, home: String = NSHomeDirectory()
    ) -> String {
        guard let path, let facts, facts.exists else { return "PsyNeuView isn't installed yet" }
        switch kind(of: facts) {
        case .bundled(let version):
            if let version { return "PsyNeuView \(version), included with this app" }
            return "PsyNeuView included with this app"
        case .checkout:
            let shown = abbreviated(path, home: home)
            if let branch { return "Your PsyNeuView checkout at \(shown), on branch \(branch)" }
            return "Your PsyNeuView checkout at \(shown)"
        }
    }

    /// `~` for the home folder, as people write paths.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        let path = normalized(path)
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - Reading the disk

    /// Read what is in a folder. The only part of this type that touches disk.
    static func facts(at url: URL) -> Facts {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return .missing
        }
        var backendIsDir: ObjCBool = false
        let hasBackend = fm.fileExists(
            atPath: url.appendingPathComponent("backend").path, isDirectory: &backendIsDir)
            && backendIsDir.boolValue
        return Facts(
            exists: true,
            hasGitDir: fm.fileExists(atPath: url.appendingPathComponent(".git").path),
            hasMakefile: fm.fileExists(atPath: url.appendingPathComponent("Makefile").path),
            hasBackend: hasBackend,
            hasBuiltFrontend: fm.fileExists(
                atPath: url.appendingPathComponent("frontend/dist/index.html").path),
            stampedVersion: BundledPsyNeuView.installedVersion(at: url))
    }

    /// The branch of a checkout, reading `.git/HEAD` directly rather than
    /// running git (which a bundled-only Mac may not have). Follows a `.git`
    /// file to a worktree's real git folder.
    static func currentBranch(at url: URL) -> String? {
        let dotGit = url.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else {
            return nil
        }
        var gitDir = dotGit
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                  pointer.hasPrefix("gitdir:") else { return nil }
            let target = pointer.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : url.appendingPathComponent(target)
        }
        guard let head = try? String(
            contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        return branch(fromHEAD: head)
    }

    /// `describe`, reading the folder.
    static func describeRunning(_ url: URL?) -> String {
        guard let url else { return describe(path: nil, facts: nil, branch: nil) }
        return describe(path: url.path, facts: facts(at: url), branch: currentBranch(at: url))
    }
}
