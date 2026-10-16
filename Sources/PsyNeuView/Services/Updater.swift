import Foundation

/// Handles updating the PsyNeuView installation by pulling latest code
/// and rebuilding the frontend. No reinstall or new DMG needed.
///
/// A pull fast-forwards the branch the checkout is on and never switches it;
/// switching is its own act, in the Development menu's branch picker.
@MainActor
final class Updater {
    private let logCollector: LogCollector
    private let preferences: Preferences
    /// For the backend port only: what PsyNeuLink is installed is the backend's
    /// to report (#132).
    private let appState: AppState
    var onOutput: ((String) -> Void)?

    /// The branch being tracked (from Preferences, defaults to "main")
    var trackingBranch: String { preferences.branch }

    init(logCollector: LogCollector, preferences: Preferences, appState: AppState) {
        self.logCollector = logCollector
        self.preferences = preferences
        self.appState = appState
    }


    /// What to refresh with, given what the backend says is installed (#132).
    ///
    /// Pure and static so it can be tested directly: the interesting part is
    /// the precedence, not the pip invocation.
    ///
    /// Refreshes the current source; never switches to a different one.
    /// Switching is a deliberate act performed in Settings, through the
    /// backend. An update that also changed the source is how a choice made in
    /// the gear icon used to be quietly undone.
    struct RefreshChoice: Equatable {
        let pipArgs: [String]
        let forceReinstall: Bool
    }

    nonisolated static func refreshArguments(
        for installed: PsyNeuLinkInstallClient.Current?,
        fallback: [String]
    ) -> RefreshChoice {
        guard let installed, let source = installed.installSource else {
            // Nothing to go on — an unreachable backend, or a source we do not
            // recognise. Using what the app remembers is usually right, and
            // refusing to update at all would be worse.
            return RefreshChoice(pipArgs: fallback, forceReinstall: false)
        }

        // A reported path wins over the reported source, and the order matters
        // more than it looks. The backend calls an editable checkout whose
        // clone has a GitHub origin `source: "github"` — right for display,
        // because that is how the user thinks of it. Acting on it would
        // reinstall from the remote and throw away their working copy.
        if let path = installed.path, !path.isEmpty {
            return RefreshChoice(pipArgs: ["-e", path], forceReinstall: true)
        }

        switch source {
        case .pypi:
            return RefreshChoice(pipArgs: ["psyneulink"], forceReinstall: false)
        case .github:
            let repo = installed.repo?.isEmpty == false
                ? installed.repo! : PsyNeuLinkSource.defaultRepo
            // The ref the user asked for, which the backend reports from pip's
            // `requested_revision` rather than the resolved commit — so a
            // branch keeps tracking rather than pinning itself (#116).
            let ref = installed.branch ?? "devel"
            return RefreshChoice(
                pipArgs: ["git+https://github.com/\(repo).git@\(ref)"], forceReinstall: true)
        case .local:
            return RefreshChoice(pipArgs: fallback, forceReinstall: true)
        }
    }

    private func log(_ message: String) {
        logCollector.add(message, source: .system)
        onOutput?(message)
    }

    /// Whether this install tracks code with git.
    ///
    /// A bundled install does not: PsyNeuView is unpacked from the app into
    /// Application Support and has no `.git`, and new code arrives through
    /// Sparkle rather than `git pull`. Running git against it fails on every
    /// launch — and on a Mac with no Command Line Tools, invoking `git` at all
    /// pops the "install developer tools" dialog that #67 removed from setup.
    /// (#87)
    nonisolated static func tracksUpdatesWithGit(repoPath: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: repoPath.appendingPathComponent(".git").path)
    }

    /// List available remote branches for the PsyNeuView repo.
    func listBranches(repoPath: URL) async -> [String] {
        _ = try? await Shell.run("git", arguments: ["fetch", "--all"], currentDirectory: repoPath)
        let result = try? await Shell.run(
            "git", arguments: ["branch", "-r", "--format=%(refname:short)"],
            currentDirectory: repoPath
        )
        guard let result, result.exitCode == 0 else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: "origin/", with: "") }
            .filter { $0 != "HEAD" && !$0.isEmpty }
            .sorted()
    }

    /// Switch to a different branch, pull, and rebuild.
    func switchBranch(to branch: String, repoPath: URL) async -> Bool {
        log("Switching to branch: \(branch)")
        preferences.branch = branch

        // Checkout the branch
        let checkoutExitCode = await Shell.runStreaming(
            "git", arguments: ["checkout", branch],
            currentDirectory: repoPath,
            onOutput: { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.log(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        )

        if checkoutExitCode != 0 {
            log("Failed to checkout branch \(branch)")
            return false
        }

        // Pull and rebuild
        return await update(repoPath: repoPath)
    }

    /// The branch the checkout is on, read from `.git/HEAD` rather than asked
    /// of git, so a bundled-only Mac never pops the developer-tools dialog.
    /// Nil for a detached HEAD or a folder that is not a checkout.
    nonisolated static func currentBranch(repoPath: URL) -> String? {
        InstallSwitch.currentBranch(at: repoPath)
    }

    /// The facts `CheckoutPull.decide` decides over (#214): the branch, the
    /// uncommitted changes, and how it stands against origin after a fetch.
    /// Never switches branch: the question is about the branch the checkout
    /// is on, not the one the app remembers.
    func pullState(repoPath: URL) async -> CheckoutPull.State {
        guard let branch = Self.currentBranch(repoPath: repoPath) else {
            return CheckoutPull.State(
                branch: nil, fetched: false, changedFiles: 0, ahead: 0, behind: 0)
        }

        let fetch = try? await Shell.run(
            "git", arguments: ["fetch", "origin", branch], currentDirectory: repoPath)
        let fetched = fetch?.exitCode == 0

        let status = try? await Shell.run(
            "git", arguments: ["status", "--porcelain", "--untracked-files=no"],
            currentDirectory: repoPath)
        let changedFiles = status?.exitCode == 0
            ? CheckoutPull.changedFiles(fromStatus: status?.stdout ?? "") : 0

        let revList = try? await Shell.run(
            "git", arguments: ["rev-list", "--left-right", "--count", "HEAD...origin/\(branch)"],
            currentDirectory: repoPath)
        // An unreadable count must not read as "up to date": treat it as the
        // fetch having told us nothing.
        let counts = revList?.exitCode == 0
            ? CheckoutPull.counts(fromRevList: revList?.stdout ?? "") : nil

        // No common ancestor at all: git merge-base exits 1. Read only after a
        // good fetch, so a network failure never looks like a moved repository.
        var unrelated = false
        if fetched {
            let base = try? await Shell.run(
                "git", arguments: ["merge-base", "HEAD", "origin/\(branch)"],
                currentDirectory: repoPath)
            unrelated = base?.exitCode == 1
        }

        return CheckoutPull.State(
            branch: branch,
            fetched: fetched && (counts != nil || unrelated),
            changedFiles: changedFiles,
            ahead: counts?.ahead ?? 0,
            behind: counts?.behind ?? 0,
            unrelated: unrelated)
    }

    /// Check if there are updates available (the checkout is behind origin's
    /// copy of the branch it is on). Read-only: it used to check out the
    /// remembered branch first, which made a self-check switch branches (#214).
    func checkForUpdates(repoPath: URL) async -> Bool {
        let state = await pullState(repoPath: repoPath)
        return state.fetched && state.behind > 0
    }

    /// Pull latest code, rebuild frontend, and return true if successful.
    /// Re-install PsyNeuLink from whichever source the user selected.
    ///
    /// Split out of `update` so the launch-time offer (#116) can refresh
    /// PsyNeuLink alone — a branch install goes stale on its own schedule,
    /// independently of the PsyNeuView code, and a bundled install has no git
    /// checkout to pull anyway.
    ///
    /// Returns false when pip is missing or the install failed. Callers decide
    /// whether that matters: inside `update` it is non-critical, but an offer
    /// the user accepted should say so when it does not work.
    /// Re-install PsyNeuLink from whichever source the user selected.
    ///
    /// Split out of `update` so the launch-time offer (#116) can refresh
    /// PsyNeuLink alone. A branch install goes stale on its own schedule,
    /// independently of the PsyNeuView code, and a bundled install has no git
    /// checkout to pull anyway.
    ///
    /// Returns false when there is no pip to run or the install failed, so a
    /// caller that promised the user an update can say when it did not happen.
    @discardableResult
    func upgradePsyNeuLink(repoPath: URL) async -> Bool {
        let outcome = await upgradePsyNeuLinkOutcome(repoPath: repoPath)
        if outcome == .installed {
            // New packages were written: do the first start's one-time work
            // now rather than behind the spinner (#223).
            await prepareFastStart(repoPath: repoPath, progress: nil)
        }
        return outcome != .failed
    }

    /// The pip arguments of the last PsyNeuLink refresh, for the fast-start
    /// preparation to know a local checkout's path.
    private var lastRefreshArgs: [String]?

    /// Compile bytecode and build the font cache after packages were
    /// written (#223), as a step the checklist shows when there is one.
    /// Only called when something was installed, so the bytecode is
    /// always due; the font cache is skipped when this Mac has it.
    private func prepareFastStart(repoPath: URL, progress: InstallProgress?) async {
        progress?.insert(.prepareFastStart, after: .updatePythonPackages)
        progress?.begin(.prepareFastStart)
        log("Preparing Python for a fast first start...")
        let plan = await FastStartPrep.run(
            repoPath: repoPath,
            pnlPipArgs: lastRefreshArgs ?? preferences.pnlPipArgs,
            packagesChanged: true,
            log: { [weak self] line in self?.log(line) },
            detail: { detail in progress?.note(detail, under: .prepareFastStart) })
        if plan.skipsEverything {
            progress?.skip(.prepareFastStart, reason: FastStartPrep.Plan.skipReason)
        } else {
            progress?.finish(.prepareFastStart)
        }
    }

    /// What a PsyNeuLink refresh did (#232): the checklist says "not needed"
    /// when it was already current, rather than counting a one-second check
    /// as an install.
    enum UpgradeOutcome: Equatable {
        case alreadyCurrent
        case installed
        case failed
    }

    func upgradePsyNeuLinkOutcome(repoPath: URL) async -> UpgradeOutcome {
        // What is installed is the backend's to report, not ours to remember.
        // This used to read the app's stored preference, which meant a source
        // chosen through the gear icon was reinstalled away at the next update
        // — silently, and long after the change (#132).
        var installedDescription = "the current source"
        var installed: PsyNeuLinkInstallClient.Current?
        if appState.backendPort > 0 {
            installed = try? await PsyNeuLinkInstallClient.current(port: appState.backendPort)
            if let installed {
                switch installed.source {
                case "pypi": installedDescription = "PyPI"
                case "github":
                    installedDescription = "GitHub (\(installed.branch ?? "default branch"))"
                case "local", "editable":
                    installedDescription = "a local checkout"
                default: break
                }
            }
        }
        log("Checking for PsyNeuLink updates (\(installedDescription))...")

        // Ask whether anything actually moved before paying for a reinstall.
        //
        // pip cannot cache a git branch URL -- "devel" may mean something else a
        // minute later -- so `pip install git+...@devel` re-clones the whole
        // repository every time, moved or not. Measured at ~105s of a 122s
        // start, which is most of what a slow launch is (#153).
        //
        // `git ls-remote` answers the same question in one round trip, and the
        // installed build already carries the commit it was made from.
        if await psyNeuLinkIsAtRemoteTip(installed: installed) {
            log("PsyNeuLink is already at the tip of its branch — nothing to reinstall.")
            return .alreadyCurrent
        }

        let venvPip = repoPath.appendingPathComponent("backend/.venv/bin/pip")
        let uvPath = Shell.bundledUvPath()
        guard FileManager.default.fileExists(atPath: venvPip.path) || uvPath != nil else {
            log("No pip or uv to run — cannot upgrade PsyNeuLink.")
            return .failed
        }

        var env = Shell.userEnvironment()
        let venvDir = repoPath.appendingPathComponent("backend/.venv")
        env["VIRTUAL_ENV"] = venvDir.path
        env["PATH"] = venvDir.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "")
        env = PsyNeuLinkInstall.environment(base: env, supportDirectory: BundledPsyNeuView.supportDirectory())

        // Refresh whatever is installed; never switch to something else.
        // Switching is a deliberate act the user performs in Settings, and it
        // goes through the backend. An update that also changed the source was
        // how a gear-icon choice got quietly undone (#132).
        //
        // Falls back to the stored preference only when the backend cannot be
        // reached — at that point there is nothing better to go on, and doing
        // nothing would leave a user unable to update at all.
        let choice = Self.refreshArguments(for: installed, fallback: preferences.pnlPipArgs)
        lastRefreshArgs = choice.pipArgs

        // The same uv the install uses, with pip behind it (#224). uv keeps
        // the source's git repository in its cache, so a branch refresh
        // fetches what moved rather than cloning PsyNeuLink again — the
        // minutes pip spent re-cloning (#153) become seconds. A refresh that
        // must not drag the dependency tree along (a reinstall of the same
        // source) is the override position; a PyPI install moving to the
        // newest release is a plain upgrade.
        let position: PsyNeuLinkInstall.Position = choice.forceReinstall ? .override : .upgrade
        if choice.forceReinstall, uvPath == nil {
            log("(PsyNeuLink installs from a git branch, so pip re-clones it — this step can take a few minutes.)")
        }
        var tool: PsyNeuLinkInstall.Tool = uvPath != nil ? .uv : .pip
        while true {
            let command = PsyNeuLinkInstall.command(tool: tool, pnlPipArgs: choice.pipArgs, position: position)
            let executable = tool == .uv ? (uvPath ?? venvPip.path) : venvPip.path
            log("Refreshing PsyNeuLink with \(tool.name)...")
            let exitCode = await Shell.runStreaming(
                executable,
                arguments: command.arguments,
                currentDirectory: repoPath.appendingPathComponent("backend"),
                environment: env,
                onOutput: streamToLog()
            )
            switch PsyNeuLinkInstall.outcome(
                exitCode: exitCode, tool: tool,
                pipAvailable: FileManager.default.fileExists(atPath: venvPip.path)) {
            case .installed:
                log("PsyNeuLink is up to date")
                return .installed
            case .retryWithPip(let reason):
                log("\(reason) — retrying with pip.")
                tool = .pip
            case .failed(let reason):
                log("PsyNeuLink upgrade failed (\(reason))")
                return .failed
            }
        }
    }

    /// The SHA named by a `git ls-remote <url> <ref>` line.
    ///
    /// Output is "<sha>\t<ref>" per line; a ref that does not exist yields no
    /// lines at all, which must read as "cannot tell", never as "up to date".
    nonisolated static func sha(fromLsRemote output: String) -> String? {
        for line in output.split(separator: "\n") {
            let candidate = String(line.split(separator: "\t").first ?? "")
                .trimmingCharacters(in: .whitespaces)
            if candidate.count >= 7, candidate.allSatisfy({ $0.isHexDigit }) {
                return candidate
            }
        }
        return nil
    }

    /// Whether reinstalling from `remoteSHA` would land on what is installed.
    ///
    /// The installed commit is abbreviated (the backend reports 7 characters,
    /// setuptools-scm embeds it in the local version segment), so this is a
    /// prefix test. Anything unknown answers false: reinstalling needlessly
    /// costs time, but skipping a needed one leaves the user on stale code with
    /// nothing said.
    nonisolated static func isAtRemoteTip(installedCommit: String?, remoteSHA: String?) -> Bool {
        guard let installedCommit, let remoteSHA,
              installedCommit.count >= 7,
              installedCommit.allSatisfy({ $0.isHexDigit })
        else { return false }
        return remoteSHA.hasPrefix(installedCommit)
    }

    /// Ask the remote whether the installed GitHub build is still its tip.
    ///
    /// Only meaningful for a GitHub install: PyPI has no branch to compare, and
    /// a local checkout is the user's own working tree.
    private func psyNeuLinkIsAtRemoteTip(installed: PsyNeuLinkInstallClient.Current?) async -> Bool {
        guard let installed,
              installed.installSource == .github,
              let repo = installed.repo, !repo.isEmpty,
              let branch = installed.branch, !branch.isEmpty
        else { return false }

        let result = try? await Shell.run(
            "git", arguments: ["ls-remote", "https://github.com/\(repo).git", branch]
        )
        guard let result, result.exitCode == 0 else { return false }
        return Self.isAtRemoteTip(
            installedCommit: installed.commit,
            remoteSHA: Self.sha(fromLsRemote: result.stdout)
        )
    }

    /// Rewrite the installed distribution metadata without touching dependencies.
    ///
    /// Only the version is expected to have moved, and Settings reads that from
    /// the metadata rather than from the source. Best effort: a failure leaves a
    /// stale version number, which is not worth blocking a launch for.
    private func refreshDistributionMetadata(repoPath: URL) async {
        let venvPip = repoPath.appendingPathComponent("backend/.venv/bin/pip")
        guard FileManager.default.fileExists(atPath: venvPip.path) else { return }

        var env = Shell.userEnvironment()
        let venvDir = repoPath.appendingPathComponent("backend/.venv")
        env["VIRTUAL_ENV"] = venvDir.path
        env["PATH"] = venvDir.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "")

        let exitCode = await Shell.runStreaming(
            venvPip.path,
            arguments: ["install", "-e", ".", "--no-deps", "-q"],
            currentDirectory: repoPath.appendingPathComponent("backend"),
            environment: env,
            onOutput: { _ in }
        )
        if exitCode != 0 {
            log("Could not refresh the version metadata; Settings may show the previous version.")
        }
    }

    /// Did anything under `path` change in the range the pull just brought in?
    ///
    /// Without a known starting commit we cannot tell, so we say yes: rebuilding
    /// needlessly costs seconds, skipping a needed rebuild serves stale code.
    private func pathChanged(_ path: String, since previousHead: String?, repoPath: URL) async -> Bool {
        guard let previousHead, !previousHead.isEmpty else { return true }
        let result = try? await Shell.run(
            "git", arguments: ["diff", "--name-only", "\(previousHead)..HEAD", "--", path],
            currentDirectory: repoPath
        )
        guard let result, result.exitCode == 0 else { return true }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The dependency-bearing fields of a pyproject.toml, canonicalised.
    ///
    /// Two files with the same signature install the same thing, so a change to
    /// the version string, description, or a comment does not warrant a
    /// reinstall. That matters because reinstalling re-resolves PsyNeuLink from
    /// a git branch URL, which pip can never serve from cache -- it re-clones
    /// the entire repository, which is minutes (#144).
    ///
    /// Returns nil when the file cannot be parsed, which callers treat as
    /// "assume it changed".
    private func dependencySignature(ofTOMLAt path: URL, python: URL) async -> String? {
        let script = """
        import json, sys, tomllib
        with open(sys.argv[1], 'rb') as fh:
            doc = tomllib.load(fh)
        project = doc.get('project', {})
        optional = project.get('optional-dependencies', {})
        print(json.dumps({
            'dependencies': sorted(project.get('dependencies', [])),
            'optional': {k: sorted(v) for k, v in sorted(optional.items())},
            'requires-python': project.get('requires-python'),
            'build-requires': sorted(doc.get('build-system', {}).get('requires', [])),
        }, sort_keys=True))
        """
        let result = try? await Shell.run(
            python.path, arguments: ["-c", script, path.path]
        )
        guard let result, result.exitCode == 0 else { return nil }
        let signature = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return signature.isEmpty ? nil : signature
    }

    /// Whether the pull actually changed what `pip install` would resolve.
    ///
    /// Compares the incoming pyproject.toml against the one from before the
    /// pull. Any uncertainty -- missing venv, unreadable blob, unparseable TOML
    /// -- resolves to true, so we reinstall rather than run against stale deps.
    private func dependenciesActuallyChanged(since previousHead: String?, repoPath: URL) async -> Bool {
        guard let previousHead, !previousHead.isEmpty else { return true }

        let python = repoPath.appendingPathComponent("backend/.venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return true }

        let previous = try? await Shell.run(
            "git", arguments: ["show", "\(previousHead):backend/pyproject.toml"],
            currentDirectory: repoPath
        )
        guard let previous, previous.exitCode == 0 else { return true }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyproject-before-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? previous.stdout.write(to: scratch, atomically: true, encoding: .utf8)) != nil else {
            return true
        }

        guard let before = await dependencySignature(ofTOMLAt: scratch, python: python),
              let after = await dependencySignature(
                  ofTOMLAt: repoPath.appendingPathComponent("backend/pyproject.toml"),
                  python: python
              )
        else { return true }

        return before != after
    }


    // MARK: - A checkout start (#232)

    /// What the pull did, for the refresh decisions.
    private struct PullOutcome {
        /// Commits came in.
        var pulled: Bool
        /// HEAD before the pull, when git could say.
        var previousHead: String?
    }

    /// Bring a checkout up to date and redo only what the pull made stale,
    /// reporting each step to `progress` (#232).
    ///
    /// Every launch of a checkout used to pull, then run `npm install` and a
    /// full `vite build` whenever anything came in, behind one spinner. Now
    /// each step is on the checklist and runs only when `CheckoutRefresh`
    /// says it has to: the interface is rebuilt when interface sources
    /// changed (or the build is missing or stale), packages are checked when
    /// the package lists changed, and a skipped step says why.
    ///
    /// Returns false when a step that ran failed. The caller starts the
    /// server either way: a failed rebuild with an older build on disk is a
    /// worse app than no app, and the checklist shows which step failed.
    ///
    /// `adoptNewHistory` is for one case only, and only when the user has
    /// said yes to it: origin's history was rebuilt, so a fast-forward is
    /// impossible. The checkout then moves onto origin's branch, keeping its
    /// own commits on a backup branch (`moveToNewHistory`). A launch never
    /// passes it.
    func update(repoPath: URL, progress: InstallProgress? = nil,
                adoptNewHistory: Bool = false) async -> Bool {
        let pull = await pullCheckout(repoPath: repoPath, progress: progress,
                                      adoptNewHistory: adoptNewHistory)
        let facts = await refreshFacts(repoPath: repoPath, pull: pull)
        let plan = CheckoutRefresh.decide(facts)
        let frontendDir = repoPath.appendingPathComponent("frontend")

        // Interface packages.
        if plan.nodePackages.runs {
            progress?.begin(.checkNodePackages)
            log("Checking interface packages (\(plan.nodePackages.reason))...")
            guard let npmPath = await Shell.which("npm") else {
                log("npm isn't installed — can't check the interface packages.")
                progress?.fail(.checkNodePackages, reason: "npm not found")
                return false
            }
            let npmExitCode = await Shell.runStreaming(
                npmPath, arguments: ["install"],
                currentDirectory: frontendDir,
                onOutput: streamToLog())
            if npmExitCode != 0 {
                log("npm install failed")
                progress?.fail(.checkNodePackages, reason: "npm install failed")
                return false
            }
            progress?.finish(.checkNodePackages)
        } else {
            log("Interface packages: \(plan.nodePackages.reason) — not running npm install.")
            progress?.skip(.checkNodePackages, reason: plan.nodePackages.reason)
        }

        // The interface itself.
        if plan.rebuildFrontend.runs {
            progress?.begin(.rebuildFrontend)
            log("Rebuilding the interface (\(plan.rebuildFrontend.reason))...")
            let vitePath = frontendDir.appendingPathComponent("node_modules/.bin/vite").path
            let buildExitCode = await Shell.runStreaming(
                "/usr/bin/env", arguments: ["node", vitePath, "build"],
                currentDirectory: frontendDir,
                onOutput: streamToLog())
            if buildExitCode != 0 {
                log("Frontend build failed")
                progress?.fail(.rebuildFrontend, reason: "vite build failed")
                return false
            }
            progress?.finish(.rebuildFrontend)
        } else {
            log("Interface: \(plan.rebuildFrontend.reason) — not rebuilding.")
            progress?.skip(.rebuildFrontend, reason: plan.rebuildFrontend.reason)
        }

        // Python packages: the backend's own when its project file changed,
        // and a PsyNeuLink refresh when the pull brought anything in.
        progress?.begin(.updatePythonPackages)
        var installedSomething = false
        if plan.pythonPackages.runs {
            // pyproject.toml also carries the version string, which changes
            // with every release (PsyNeuView #1146); reinstalling for that
            // alone costs a full PsyNeuLink re-clone (#144).
            let depsChanged = await dependenciesActuallyChanged(
                since: pull.previousHead, repoPath: repoPath)
            if depsChanged {
                log("Backend dependencies changed — reinstalling from pyproject.toml...")
                let venvPip = repoPath.appendingPathComponent("backend/.venv/bin/pip")
                var env = Shell.userEnvironment()
                let venvDir = repoPath.appendingPathComponent("backend/.venv")
                env["VIRTUAL_ENV"] = venvDir.path
                env["PATH"] = venvDir.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "")
                let pipExitCode = await Shell.runStreaming(
                    venvPip.path,
                    arguments: ["install", "-e", "."],
                    currentDirectory: repoPath.appendingPathComponent("backend"),
                    environment: env,
                    onOutput: streamToLog())
                if pipExitCode != 0 {
                    log("pip install failed")
                    progress?.fail(.updatePythonPackages, reason: "pip install failed")
                    return false
                }
                installedSomething = true
            } else {
                log("pyproject.toml changed, but no dependencies moved — skipping reinstall")
                // Settings reports the *installed distribution* metadata,
                // which only pip rewrites; without this the version goes
                // stale (#154). --no-deps costs ~2 s and can't re-clone.
                await refreshDistributionMetadata(repoPath: repoPath)
            }
        }
        if pull.pulled {
            // Re-applies the user's preferred PsyNeuLink source on top; says
            // "already at the tip" and does nothing when it is.
            // Not fatal when it fails: the server runs with the PsyNeuLink it has.
            if await upgradePsyNeuLinkOutcome(repoPath: repoPath) == .installed {
                installedSomething = true
            }
        }
        if installedSomething {
            progress?.finish(.updatePythonPackages)
            await prepareFastStart(repoPath: repoPath, progress: progress)
        } else {
            let reason = plan.pythonPackages.runs ? "no dependencies moved" : plan.pythonPackages.reason
            progress?.skip(.updatePythonPackages, reason: reason)
        }

        if pull.pulled {
            log("✓ Update complete.")
        }
        return true
    }

    /// Fast-forward the checkout to origin's copy of its branch, if it is
    /// behind and may be moved (#214). Says on the checklist when there was
    /// nothing to do, and why when it must not.
    private func pullCheckout(repoPath: URL, progress: InstallProgress?,
                              adoptNewHistory: Bool = false) async -> PullOutcome {
        progress?.begin(.pullCheckout)

        // Record where we are first. A fast-forward routinely advances
        // several commits, and the refresh decisions have to look at all of
        // them: HEAD~1..HEAD only ever describes the last one (#145).
        let beforePull = try? await Shell.run(
            "git", arguments: ["rev-parse", "HEAD"], currentDirectory: repoPath)
        let previousHead = beforePull?.exitCode == 0
            ? beforePull?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        let state = await pullState(repoPath: repoPath)
        if adoptNewHistory, CheckoutPull.mayAdoptNewHistory(state), let branch = state.branch {
            let say: @Sendable (String) -> Void = { [weak self] text in
                Task { @MainActor [weak self] in self?.log(text) }
            }
            if await Self.moveToNewHistory(branch: branch, repoPath: repoPath, log: say) {
                progress?.finish(.pullCheckout)
                // Everything may have changed: the refresh compares against
                // where the checkout was, so it rebuilds what it must.
                return PullOutcome(pulled: true, previousHead: previousHead)
            }
            progress?.fail(.pullCheckout, reason: "couldn't move to the new history")
            return PullOutcome(pulled: false, previousHead: previousHead)
        }
        switch CheckoutPull.decide(state) {
        case .refuse(let why):
            log(why)
            progress?.skip(.pullCheckout, reason: Self.pullSkipReason(for: state))
            return PullOutcome(pulled: false, previousHead: previousHead)
        case .nothingToPull(let why):
            log(why)
            progress?.skip(.pullCheckout, reason: Self.pullSkipReason(for: state))
            return PullOutcome(pulled: false, previousHead: previousHead)
        case .pull(let branch):
            // `pullState` has just fetched, so this is the fast-forward alone
            // — no second round trip — on the branch the checkout is on,
            // never the one the app remembers: a pull must not switch branch.
            log("Fast-forwarding \(branch) to origin/\(branch)...")
            let exitCode = await Shell.runStreaming(
                "git", arguments: ["merge", "--ff-only", "origin/\(branch)"],
                currentDirectory: repoPath,
                onOutput: streamToLog())
            if exitCode != 0 {
                log("Git fast-forward failed. Local changes or a diverged branch "
                    + "need resolving in the checkout by hand.")
                progress?.fail(.pullCheckout, reason: "fast-forward failed")
                return PullOutcome(pulled: false, previousHead: previousHead)
            }
            progress?.finish(.pullCheckout)
            return PullOutcome(pulled: true, previousHead: previousHead)
        }
    }

    /// Move the checkout onto origin's rebuilt history: keep its own commits
    /// on a backup branch, then `git reset --keep origin/<branch>`, which
    /// leaves untracked files alone and refuses rather than overwrite one.
    /// The caller has checked `CheckoutPull.mayAdoptNewHistory` (nothing
    /// tracked is changed) and the user has agreed. Static so it can be tested
    /// against real repositories.
    nonisolated static func moveToNewHistory(
        branch: String, repoPath: URL, on date: Date = Date(),
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let backup = CheckoutPull.backupBranch(for: branch, on: date)
        let saved = try? await Shell.run(
            "git", arguments: ["branch", "-f", backup, "HEAD"], currentDirectory: repoPath)
        guard saved?.exitCode == 0 else {
            log("Couldn't keep this checkout's commits on \(backup); not moved.")
            return false
        }
        log("This checkout's commits are kept on branch \(backup).")
        log("Moving \(branch) to origin/\(branch) (the rebuilt history)...")
        let reset = try? await Shell.run(
            "git", arguments: ["reset", "--keep", "origin/\(branch)"], currentDirectory: repoPath)
        guard reset?.exitCode == 0 else {
            let why = (reset?.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            log("Couldn't move \(branch) to the new history; nothing was changed. "
                + "Its old commits are on \(backup)." + (why.isEmpty ? "" : " git: \(why)"))
            return false
        }
        log("✓ \(branch) now follows the rebuilt history.")
        return true
    }

    /// A few words for the checklist when the pull didn't happen; the log
    /// has the full sentence from `CheckoutPull`.
    nonisolated static func pullSkipReason(for state: CheckoutPull.State) -> String {
        guard state.branch != nil else { return "not on a branch" }
        guard state.fetched else { return "couldn't reach origin" }
        if state.unrelated { return "PsyNeuView's history was rebuilt; not pulled" }
        if state.changedFiles > 0 { return "local changes; not pulled" }
        if state.ahead > 0 && state.behind > 0 { return "diverged from origin; not pulled" }
        if state.ahead > 0 { return "ahead of origin" }
        return "already up to date"
    }

    /// What `CheckoutRefresh` decides over: the pull's changed paths and the
    /// state of the tree.
    private func refreshFacts(repoPath: URL, pull: PullOutcome) async -> CheckoutRefresh.Facts {
        var changed: [String]?
        if pull.pulled {
            if let previousHead = pull.previousHead, !previousHead.isEmpty {
                let diff = try? await Shell.run(
                    "git", arguments: ["diff", "--name-only", previousHead, "HEAD"],
                    currentDirectory: repoPath)
                if let diff, diff.exitCode == 0 {
                    changed = CheckoutRefresh.changedPaths(fromDiff: diff.stdout)
                    log("The pull changed \(changed?.count ?? 0) file(s).")
                }
            }
        } else {
            changed = []
        }

        let frontend = repoPath.appendingPathComponent("frontend")
        let fm = FileManager.default
        let distIndex = frontend.appendingPathComponent("dist/index.html")
        let nodeModulesPresent = fm.fileExists(atPath: frontend.appendingPathComponent("node_modules").path)
        let distPresent = fm.fileExists(atPath: distIndex.path)
        var older = false
        if distPresent {
            let distDate = (try? fm.attributesOfItem(atPath: distIndex.path))?[.modificationDate] as? Date
            let newest = await Task.detached(priority: .userInitiated) {
                Self.newestModification(under: frontend)
            }.value
            older = CheckoutRefresh.isOlder(distModified: distDate, newestSource: newest)
        }
        return CheckoutRefresh.Facts(
            pulled: pull.pulled, changedPaths: changed,
            nodeModulesPresent: nodeModulesPresent, distPresent: distPresent,
            distOlderThanSources: older)
    }

    /// The newest modification date among the interface's sources: everything
    /// under `frontend/` except what isn't built into it (packages, the build
    /// itself, the end-to-end tests, hidden files).
    nonisolated static func newestModification(under frontend: URL) -> Date? {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", "dist", "e2e", "tests", "test", "playwright-report", "test-results"]
        guard let walk = fm.enumerator(
            at: frontend, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var newest: Date?
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skip.contains(url.lastPathComponent) { walk.skipDescendants() }
                continue
            }
            if let date = values?.contentModificationDate, newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }
        return newest
    }

    private func streamToLog() -> @Sendable (String) -> Void {
        { [weak self] text in
            Task { @MainActor [weak self] in
                self?.log(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
