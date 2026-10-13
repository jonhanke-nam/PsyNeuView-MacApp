import Foundation

/// How PsyNeuLink should be installed.
enum PsyNeuLinkSource: String {
    /// Install from PyPI (the official release).
    case pypi = "pypi"
    /// Install from a branch of a GitHub repo (defaults to Princeton; forks supported via `repo`).
    case github = "github"
    /// Install a checkout already on this machine, editable and in place — for
    /// people who develop PsyNeuLink and want PsyNeuView to run *their* tree
    /// rather than a release or a fresh clone of it. (#56)
    case local = "local"

    /// Default GitHub repo when the user hasn't picked a fork.
    static let defaultRepo = "PrincetonUniversity/PsyNeuLink"

    /// How Settings names a source in its status line: "PyPI",
    /// "GitHub PrincetonUniversity/PsyNeuLink @ devel", "your checkout at
    /// /path". Says what was saved, so the user can check it's what they
    /// meant (#172).
    func displayName(branch: String, repo: String, localPath: String) -> String {
        switch self {
        case .pypi:
            return "PyPI"
        case .github:
            let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
            return "GitHub \(r.isEmpty ? Self.defaultRepo : r) @ \(branch)"
        case .local:
            let path = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            return "your checkout at \(shown)"
        }
    }

    /// Validate an `owner/repo` string. Empty input is allowed (means "use default").
    static func isValidRepo(_ repo: String) -> Bool {
        if repo.isEmpty { return true }
        return repo.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil
    }

    /// The pip arguments for this source. `repo` empty → fall back to default.
    ///
    /// An argument *list* rather than a single string because an editable
    /// install is two arguments (`-e <path>`), which no single token expresses.
    func pipInstallArgs(branch: String, repo: String = "", localPath: String = "") -> [String] {
        switch self {
        case .pypi:
            return ["psyneulink"]
        case .github:
            let owner = repo.isEmpty ? Self.defaultRepo : repo
            return ["git+https://github.com/\(owner).git@\(branch)"]
        case .local:
            return ["-e", localPath]
        }
    }

    /// Does this folder look like a PsyNeuLink checkout? Checked before
    /// installing, so a mistyped path fails with an explanation rather than a
    /// wall of pip output.
    static func isValidLocalCheckout(_ path: String) -> Bool {
        if path.isEmpty { return false }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let hasPackage = fm.fileExists(
            atPath: url.appendingPathComponent("psyneulink").path, isDirectory: &isDir
        ) && isDir.boolValue
        let hasSetup = fm.fileExists(atPath: url.appendingPathComponent("setup.py").path)
        return hasPackage && hasSetup
    }

    /// Well-known branches from the Princeton repo.
    static let knownBranches = ["master", "devel"]

    /// Whether a branch is considered stable (passes all tests).
    static func isStable(_ branch: String) -> Bool {
        return branch == "master" || branch == "devel"
    }
}

@Observable
final class Preferences {
    /// Branches always shown in the picker (the tested trunks). Feature/unstable
    /// branches only appear in Developer mode. (#34)
    static let alwaysVisibleBranches = ["devel", "main"]

    /// Filter a branch list for the picker: everything in Developer mode; only
    /// the tested trunks (+ whatever branch is currently checked out, so a user
    /// can always switch away) otherwise. Pure + static so it's unit-testable.
    static func visibleBranches(_ all: [String], developerMode: Bool, current: String) -> [String] {
        if developerMode { return all }
        return all.filter { alwaysVisibleBranches.contains($0) || $0 == current }
    }

    private static let repoPathKey = "repoPath"
    private static let autoRestartKey = "autoRestart"
    private static let launchAtLoginKey = "launchAtLogin"
    private static let developerModeKey = "developerMode"
    private static let useBundledAppKey = "useBundledApp"
    private static let branchKey = "branch"
    private static let pnlSourceKey = "pnlSource"
    private static let pnlBranchKey = "pnlBranch"
    private static let pnlRepoKey = "pnlRepo"
    private static let pnlUpdateOffersMutedKey = "pnlUpdateOffersMuted"
    private static let pnlLocalPathKey = "pnlLocalPath"
    private static let recentCheckoutsKey = "recentCheckouts"
    private static let reportSendWithKey = "reportSendWith"
    private static let reportSendToKey = "reportSendTo"
    private static let lastMoveOutcomeKey = "lastMoveOutcome"
    private static let tooOldOfferDismissedKey = "tooOldOfferDismissed"

    var repoPath: URL? {
        didSet { save() }
    }
    var autoRestart: Bool {
        didSet { save() }
    }
    var launchAtLogin: Bool {
        didSet { save() }
    }
    /// Developer mode: surfaces all branches in the branch picker (including
    /// unstable feature branches). Off by default so casual users can only
    /// switch between the tested branches (devel/main). (#34)
    /// Use the PsyNeuView shipped inside the app rather than cloning one.
    ///
    /// Default true: the bundled path needs no GitHub account, no repo access and
    /// no git, and is what most people want. Turning it off restores the clone —
    /// for editing the checkout or working alongside PyCharm. (#74)
    var useBundledApp: Bool {
        didSet { save() }
    }

    var developerMode: Bool {
        didSet { save() }
    }
    /// The PsyNeuView branch to track. Defaults to "devel" (the active,
    /// CI-tested trunk; `main` is dormant and ~months behind).
    var branch: String {
        didSet { save() }
    }
    /// Where to install PsyNeuLink from. Defaults to the Princeton GitHub
    /// `devel` branch, so bundled/library models and features match the
    /// PsyNeuView we build against (PyPI trails and lacks e.g. the EGO library
    /// model). Users can switch to PyPI or another branch in Preferences.
    var pnlSource: PsyNeuLinkSource {
        didSet { save() }
    }
    /// The PsyNeuLink GitHub branch to use (only applies when pnlSource == .github).
    /// Defaults to "devel".
    var pnlBranch: String {
        didSet { save() }
    }
    /// Whether the user has asked not to be offered PsyNeuLink updates. (#116)
    ///
    /// Set by "Don't ask again" in the offer. Deliberately does not disable the
    /// Settings freshness row: muting the prompt is not the same as choosing
    /// not to know, and someone who silenced a dialog should still be able to
    /// find out how far behind they are when they go looking.
    var pnlUpdateOffersMuted: Bool {
        didSet { save() }
    }

    /// The PsyNeuLink GitHub repo to install from (owner/repo). Empty → Princeton default.
    /// Only applies when pnlSource == .github.
    var pnlRepo: String {
        didSet { save() }
    }

    /// Path to a local PsyNeuLink checkout (only applies when pnlSource == .local).
    var pnlLocalPath: String {
        didSet { save() }
    }

    /// PsyNeuView checkouts used before, most recent first, offered in
    /// Settings so switching back to one is a pick rather than a hunt (#195).
    var recentCheckouts: [String] {
        didSet { save() }
    }

    /// How Report a Problem offers to send a saved report (#202): "ask",
    /// "mail", "outlook" or "gmail". Set in PsyNeuView's Settings, Mac app
    /// section, through the `pnvSettings` bridge.
    var reportSendWith: String {
        didSet { save() }
    }

    /// The address a report is addressed to (#202). Defaults to
    /// `ReportDefaults.contactEmail`; empty also means that default.
    var reportSendTo: String {
        didSet { save() }
    }

    /// What happened the last time a launch tried to move to the PsyNeuView
    /// this app carries (#186), with its date, for Report a Problem (#202).
    /// Empty when no move has been tried.
    var lastMoveOutcome: String {
        didSet { save() }
    }

    /// The install and version whose too-old offer got "Not Now"
    /// (`SettingsSupport.dismissalKey`, #205), so launch doesn't repeat it.
    var tooOldOfferDismissed: String {
        didSet { save() }
    }

    /// The pip arguments for the current PsyNeuLink configuration.
    var pnlPipArgs: [String] {
        pnlSource.pipInstallArgs(branch: pnlBranch, repo: pnlRepo, localPath: pnlLocalPath)
    }

    /// Short human-readable description of the active source, for logs and
    /// the self-check.
    var pnlSourceDescription: String {
        switch pnlSource {
        case .pypi: return "pypi"
        case .github: return "github:\(pnlBranch)"
        case .local: return "local:\(pnlLocalPath)"
        }
    }

    var isConfigured: Bool {
        repoPath != nil
    }

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.repoPathKey) {
            self.repoPath = URL(fileURLWithPath: path)
        } else {
            self.repoPath = nil
        }
        self.autoRestart = defaults.bool(forKey: Self.autoRestartKey)
        self.launchAtLogin = defaults.bool(forKey: Self.launchAtLoginKey)
        self.developerMode = defaults.bool(forKey: Self.developerModeKey)
        // Absent means a fresh install, which should get the bundled app.
        self.useBundledApp = defaults.object(forKey: Self.useBundledAppKey) as? Bool ?? true
        self.branch = defaults.string(forKey: Self.branchKey) ?? "devel"
        self.pnlSource = PsyNeuLinkSource(rawValue: defaults.string(forKey: Self.pnlSourceKey) ?? "github") ?? .github
        self.pnlBranch = defaults.string(forKey: Self.pnlBranchKey) ?? "devel"
        self.pnlRepo = defaults.string(forKey: Self.pnlRepoKey) ?? ""
        self.pnlUpdateOffersMuted = defaults.bool(forKey: Self.pnlUpdateOffersMutedKey)
        self.pnlLocalPath = defaults.string(forKey: Self.pnlLocalPathKey) ?? ""
        self.recentCheckouts = defaults.stringArray(forKey: Self.recentCheckoutsKey) ?? []
        self.reportSendWith = defaults.string(forKey: Self.reportSendWithKey) ?? "ask"
        self.reportSendTo = defaults.string(forKey: Self.reportSendToKey) ?? ReportDefaults.contactEmail
        self.lastMoveOutcome = defaults.string(forKey: Self.lastMoveOutcomeKey) ?? ""
        self.tooOldOfferDismissed = defaults.string(forKey: Self.tooOldOfferDismissedKey) ?? ""
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(repoPath?.path, forKey: Self.repoPathKey)
        defaults.set(autoRestart, forKey: Self.autoRestartKey)
        defaults.set(launchAtLogin, forKey: Self.launchAtLoginKey)
        defaults.set(developerMode, forKey: Self.developerModeKey)
        defaults.set(useBundledApp, forKey: Self.useBundledAppKey)
        defaults.set(branch, forKey: Self.branchKey)
        defaults.set(pnlSource.rawValue, forKey: Self.pnlSourceKey)
        defaults.set(pnlBranch, forKey: Self.pnlBranchKey)
        defaults.set(pnlRepo, forKey: Self.pnlRepoKey)
        defaults.set(pnlUpdateOffersMuted, forKey: Self.pnlUpdateOffersMutedKey)
        defaults.set(pnlLocalPath, forKey: Self.pnlLocalPathKey)
        defaults.set(recentCheckouts, forKey: Self.recentCheckoutsKey)
        defaults.set(reportSendWith, forKey: Self.reportSendWithKey)
        defaults.set(reportSendTo, forKey: Self.reportSendToKey)
        defaults.set(lastMoveOutcome, forKey: Self.lastMoveOutcomeKey)
        defaults.set(tooOldOfferDismissed, forKey: Self.tooOldOfferDismissedKey)
    }
}
