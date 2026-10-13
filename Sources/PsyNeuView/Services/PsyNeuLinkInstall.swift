import Foundation

/// How PsyNeuLink is installed (#224): with the bundled uv when the app
/// carries one, with pip when it doesn't or when uv fails.
///
/// pip installed PsyNeuLink until now, and spent 27 s of a first launch
/// unzipping 183 wheels into the environment — bytes it had just written
/// once already, into its own cache (#215). uv keeps wheels unpacked in its
/// cache and installs them by cloning (APFS copy-on-write), so the install
/// phase is a second rather than half a minute, and a repair or an update
/// writes almost nothing. It also keeps a git repository per source, so a
/// branch update fetches what moved instead of cloning PsyNeuLink again.
///
/// Pure: which source and where in the install the run sits come in, the
/// command comes out. `Installer` and `Updater` run it.
enum PsyNeuLinkInstall {

    /// The kind of source `pnlPipArgs` names — the three shapes
    /// `PsyNeuLinkSource.pipInstallArgs` produces.
    enum Kind: Equatable, Sendable {
        /// `["psyneulink"]`: the release on PyPI.
        case pypi
        /// `["git+https://github.com/<owner>/<repo>.git@<ref>"]`: a branch,
        /// tag or commit on GitHub.
        case git(url: String)
        /// `["-e", "<path>"]`: a local checkout, installed editable.
        case local(path: String)
    }

    /// What the pip arguments name, or nil for a shape this app never makes.
    static func kind(of pnlPipArgs: [String]) -> Kind? {
        if pnlPipArgs == ["psyneulink"] { return .pypi }
        if pnlPipArgs.count == 1, pnlPipArgs[0].hasPrefix("git+") { return .git(url: pnlPipArgs[0]) }
        if pnlPipArgs.count == 2, pnlPipArgs[0] == "-e", !pnlPipArgs[1].isEmpty {
            return .local(path: pnlPipArgs[1])
        }
        return nil
    }

    /// Where in the install the run sits (#115).
    enum Position: Equatable, Sendable {
        /// A fresh environment: the chosen source goes in first and brings
        /// its own dependencies, so the backend's own install afterwards
        /// finds `psyneulink` satisfied and never downloads the PyPI wheel.
        case first
        /// An environment that already holds a PsyNeuLink — a repair, a
        /// source change, an update: replace it with the chosen source and
        /// leave its dependency tree alone.
        case override
        /// A PyPI install moving to the newest release (`Updater`): an
        /// ordinary upgrade, dependencies included — nothing to force.
        case upgrade
    }

    enum Tool: Equatable, Sendable {
        case uv
        case pip

        var name: String {
            switch self {
            case .uv: return "uv"
            case .pip: return "pip"
            }
        }
    }

    /// One installer run, ready for `Shell.runStreaming`.
    struct Command: Equatable, Sendable {
        var tool: Tool
        /// The arguments after the executable.
        var arguments: [String]
        /// For the log and the timeline: "PsyNeuLink (git+…@devel) with uv".
        var label: String
        /// A short, stable name for the run's timings.
        var timelineID: String
    }

    /// How uv writes files from its cache into the environment.
    ///
    /// `clone` is an APFS copy-on-write clone: instant, no bytes written
    /// twice, and the environment's files stay its own — a hard link would
    /// make a file in site-packages and the cached copy one inode, so
    /// anything that rewrites a file in place (pip refreshing a RECORD, a
    /// tool editing a `.pth`) would quietly change the cache too. Hard
    /// links also fail outright across volumes; when a clone can't be made
    /// (a non-APFS or a different volume), uv falls back to copying on its
    /// own, which is what pip did all along.
    static let linkMode = "clone"

    /// The command that installs the source with `tool`, sitting at
    /// `position` in the install.
    ///
    /// Running first, PsyNeuLink must bring its own dependencies, so no
    /// `--no-deps` — nothing has installed them yet. Running second (the
    /// override), `--no-deps` is what keeps a reinstall from churning a
    /// dependency tree that is already in place, torch included; with uv,
    /// `--reinstall-package` names the one package to replace, and
    /// `--refresh-package` makes it ask the branch for its tip rather than
    /// trusting the commit it cached last time.
    static func command(tool: Tool, pnlPipArgs: [String], position: Position) -> Command {
        let source = pnlPipArgs.joined(separator: " ")
        let arguments: [String]
        switch (tool, position) {
        case (.uv, .first):
            arguments = ["pip", "install", "--link-mode=\(linkMode)"] + pnlPipArgs
        case (.uv, .override):
            arguments = ["pip", "install", "--link-mode=\(linkMode)",
                         "--upgrade", "--no-deps",
                         "--reinstall-package", "psyneulink",
                         "--refresh-package", "psyneulink"] + pnlPipArgs
        case (.uv, .upgrade):
            arguments = ["pip", "install", "--link-mode=\(linkMode)", "--upgrade"] + pnlPipArgs
        case (.pip, .first):
            arguments = ["install"] + pnlPipArgs
        case (.pip, .override):
            arguments = ["install", "--upgrade", "--force-reinstall", "--no-deps"] + pnlPipArgs
        case (.pip, .upgrade):
            arguments = ["install", "--upgrade"] + pnlPipArgs
        }
        let what: String
        let id: String
        switch position {
        case .first: what = "PsyNeuLink"; id = "psyneulink"
        case .override: what = "PsyNeuLink override"; id = "psyneulinkOverride"
        case .upgrade: what = "PsyNeuLink upgrade"; id = "psyneulinkUpgrade"
        }
        return Command(
            tool: tool,
            arguments: arguments,
            label: "\(what) (\(source)) with \(tool.name)",
            timelineID: id)
    }

    /// What to do after a run ended.
    enum Outcome: Equatable, Sendable {
        case installed
        /// uv didn't manage it; pip gets the same job, for this reason.
        case retryWithPip(reason: String)
        case failed(reason: String)
    }

    /// uv's failure is pip's turn, whatever the cause — a build backend uv
    /// can't drive, a git it can't run, a cache it can't write. A slow
    /// install is much better than no install (#94), and pip's output says
    /// what uv's didn't. pip's failure is the end.
    static func outcome(exitCode: Int32, tool: Tool, pipAvailable: Bool) -> Outcome {
        if exitCode == 0 { return .installed }
        let reason = "\(tool.name) exited with code \(exitCode)"
        if tool == .uv, pipAvailable { return .retryWithPip(reason: reason) }
        return .failed(reason: reason)
    }

    /// Where uv keeps what it downloads and the git repositories it fetches
    /// from: in the app's own support folder, next to the install, so a
    /// repair or an update reuses every wheel and fetches only new commits.
    /// Not `~/.cache/uv`: a user's own uv (if any) shouldn't be sharing a
    /// cache with the app, and the app's cache should go when the app's
    /// data goes.
    static func cacheDirectory(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("uv-cache")
    }

    /// The environment uv runs with. A `UV_CACHE_DIR` already in the
    /// environment wins — the release checks and the first-launch profile
    /// set one to measure a cold cache — otherwise the app's own.
    static func environment(base: [String: String], supportDirectory: URL) -> [String: String] {
        var env = base
        if env["UV_CACHE_DIR"]?.isEmpty ?? true {
            env["UV_CACHE_DIR"] = cacheDirectory(supportDirectory: supportDirectory).path
        }
        return env
    }
}
