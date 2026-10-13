import Foundation

enum InstallStep: String, CaseIterable, Sendable {
    // Prerequisites (auto-installed if missing)
    case xcodeTools = "Developer tools"
    case githubAuth = "GitHub sign-in"
    case python = "Python runtime"
    case node = "Node.js 18+"
    // Application setup
    case cloneRepo = "Clone PsyNeuView repository"
    case createVenv = "Create Python virtual environment"
    case installPythonDeps = "Install Python dependencies"
    /// Bytecode and the font cache, after the packages (#223).
    case prepareFastStart = "Prepare Python for a fast first start"
    case installNodeDeps = "Install Node.js dependencies"
    case buildFrontend = "Build frontend for production"
}

enum InstallStepStatus: Sendable, Equatable {
    case pending
    case running
    case completed
    /// Not needed this time, and why (#232): "already prepared".
    case skipped(String)
    case failed(String)
}

@MainActor
final class Installer {
    var stepStatuses: [InstallStep: InstallStepStatus] = [:] {
        didSet {
            guard let onStepChange else { return }
            for step in InstallStep.allCases where stepStatuses[step] != oldValue[step] {
                if let status = stepStatuses[step] { onStepChange(step, status) }
            }
        }
    }
    /// Each step's change as it happens, for the progress view (#196).
    var onStepChange: ((InstallStep, InstallStepStatus) -> Void)?
    var currentOutput: String = ""
    var onOutput: ((String) -> Void)?
    /// A timed part of a step (#215): each phase of each pip or uv run and
    /// each run's total, under the package install; each command of the
    /// fast-start preparation, under its own step (#223).
    var onDetail: ((InstallStep, InstallProgress.Detail) -> Void)?

    private let depInstaller = DependencyInstaller()

    /// The installer run being timed, if any, and the tail of its output not
    /// yet ended by a newline — pip and uv arrive in chunks, not lines.
    private var timeline: InstallTimeline?
    private var partialLine = ""

    init() {
        for step in InstallStep.allCases {
            stepStatuses[step] = .pending
        }
    }

    /// Run the complete install pipeline.
    /// repoPath: where to clone/find the PsyNeuView repo
    /// needsClone: true if repoPath is empty and needs cloning
    /// pnlPipArgs: the pip arguments for PsyNeuLink — ["psyneulink"],
    /// ["git+https://..."], or ["-e", "/path/to/checkout"] for a local one.
    /// The directory the install actually used — the unpacked bundle in bundled
    /// mode, or the clone the caller asked for. Callers persist this. (#74)
    private(set) var resolvedRepoPath: URL?

    func installAll(
        repoPath: URL,
        needsClone: Bool,
        pnlPipArgs: [String] = ["psyneulink"],
        useBundled: Bool = true
    ) async -> Bool {
        // Bundled unless asked otherwise, and only if this build actually carries
        // an archive — a developer build that skipped `make psyneuview-bundle`
        // falls back to the clone.
        let bundled = useBundled && BundledPsyNeuView.archiveURL() != nil
        // Wire up dependency installer output
        depInstaller.onOutput = { [weak self] text in
            self?.appendOutput(text)
        }

        // Backstop. The launch-time prompt (#109) is the real defence — a line in
        // a scrolling install log is not something anyone reads. This remains for
        // the case where the user declined the move. (#66)
        if !VenvHealth.isRunningFromApplications() {
            appendOutput(
                "Note: PsyNeuView is running from \(Bundle.main.bundlePath).\n"
                + "  Move it to /Applications before setup — otherwise the Python environment\n"
                + "  will need rebuilding once the app is moved.\n")
        }

        // ── Prerequisites ──

        // 1. Xcode CLI tools (for git)
        // Command Line Tools exist here only to provide `git`, and a bundled
        // install never clones: PsyNeuView arrives with the app, and updates
        // arrive through Sparkle rather than `git pull`. Skipping this also skips
        // a system dialog the user would otherwise have to click through. (#67)
        if bundled {
            stepStatuses[.xcodeTools] = .completed
            appendOutput("Developer tools not required — nothing to clone or pull.\n")
        } else {
            stepStatuses[.xcodeTools] = .running
            if await depInstaller.installXcodeCliTools() {
                stepStatuses[.xcodeTools] = .completed
            } else {
                stepStatuses[.xcodeTools] = .failed("Failed to install Xcode Command Line Tools")
                return false
            }
        }

        // 2. GitHub sign-in — only to clone. A bundled install has nothing to
        // fetch, so asking someone to authorise a GitHub account they may not
        // even have would be gratuitous, and would defeat the point of #74.
        if bundled {
            stepStatuses[.githubAuth] = .completed
            appendOutput("GitHub sign-in not required — PsyNeuView is included in this app.\n")
        } else {
            stepStatuses[.githubAuth] = .running
            if await depInstaller.authenticateGitHub() {
                stepStatuses[.githubAuth] = .completed
            } else {
                stepStatuses[.githubAuth] = .failed("GitHub sign-in failed. Please try again.")
                return false
            }
        }

        // 3. Python
        stepStatuses[.python] = .running
        if await depInstaller.installPython() {
            stepStatuses[.python] = .completed
        } else {
            stepStatuses[.python] = .failed("Failed to install Python")
            return false
        }

        // 4. Node.js — only for the clone path. A bundled PsyNeuView ships its
        // frontend already built, so no user ever needs Node. (#74, closes #65)
        if bundled {
            stepStatuses[.node] = .completed
            appendOutput("Node.js not required — the bundled PsyNeuView ships a built frontend.\n")
        } else {
            stepStatuses[.node] = .running
            if await depInstaller.installNode() {
                stepStatuses[.node] = .completed
            } else {
                stepStatuses[.node] = .failed("Failed to install Node.js")
                return false
            }
        }

        // ── Application Setup ──

        // 5. Obtain PsyNeuView itself
        var repoPath = repoPath
        if bundled {
            stepStatuses[.cloneRepo] = .running
            do {
                repoPath = try await BundledPsyNeuView.ensureUnpacked { [weak self] line in
                    self?.appendOutput(line + "\n")
                }
                stepStatuses[.cloneRepo] = .completed
            } catch {
                stepStatuses[.cloneRepo] = .failed(error.localizedDescription)
                return false
            }
        } else if needsClone {
            stepStatuses[.cloneRepo] = .running
            if await depInstaller.cloneRepo(into: repoPath) {
                stepStatuses[.cloneRepo] = .completed
            } else {
                stepStatuses[.cloneRepo] = .failed("Failed to clone repository")
                return false
            }
        } else {
            appendOutput("Repository already present at \(repoPath.path)\n")
            stepStatuses[.cloneRepo] = .completed
        }

        // Verify repo structure
        let backendDir = repoPath.appendingPathComponent("backend")
        guard FileManager.default.fileExists(atPath: backendDir.path) else {
            appendOutput("ERROR: backend/ directory not found at \(repoPath.path)\n")
            stepStatuses[.createVenv] = .failed("backend/ not found after clone")
            return false
        }

        // 6. Create venv
        stepStatuses[.createVenv] = .running
        if await createVenv(repoPath: repoPath) {
            stepStatuses[.createVenv] = .completed
        } else {
            return false
        }

        // 7. Install Python deps
        stepStatuses[.installPythonDeps] = .running
        if await installPythonDeps(repoPath: repoPath, pnlPipArgs: pnlPipArgs) {
            stepStatuses[.installPythonDeps] = .completed
        } else {
            return false
        }

        // 7b. Do the first start's one-time work now, with progress showing (#223).
        await prepareFastStart(repoPath: repoPath, pnlPipArgs: pnlPipArgs)

        // 8. Node deps + frontend build — clone path only; the bundle ships dist/.
        if bundled {
            stepStatuses[.installNodeDeps] = .completed
            stepStatuses[.buildFrontend] = .completed
        } else {
            stepStatuses[.installNodeDeps] = .running
            if await installNodeDeps(repoPath: repoPath) {
                stepStatuses[.installNodeDeps] = .completed
            } else {
                return false
            }
        }

        // 9. Build frontend — clone path only.
        if !bundled {
            stepStatuses[.buildFrontend] = .running
            if await buildFrontend(repoPath: repoPath) {
                stepStatuses[.buildFrontend] = .completed
            } else {
                return false
            }
        }

        resolvedRepoPath = repoPath

        appendOutput("\n✓ All steps completed successfully!\n")
        return true
    }

    /// Rebuild the Python environment for a tree that is already in place.
    ///
    /// The app knows how to do this — it is what setup does — so finding the
    /// environment missing should be something it fixes rather than something it
    /// reports and stops on. Runs the same steps setup runs, against the same
    /// tree. (#106)
    func repairEnvironment(repoPath: URL, pnlPipArgs: [String] = ["psyneulink"]) async -> Bool {
        depInstaller.onOutput = { [weak self] text in self?.appendOutput(text) }

        stepStatuses[.python] = .running
        guard await depInstaller.installPython() else {
            stepStatuses[.python] = .failed("No usable Python")
            return false
        }
        stepStatuses[.python] = .completed

        stepStatuses[.createVenv] = .running
        guard await createVenv(repoPath: repoPath) else { return false }
        stepStatuses[.createVenv] = .completed

        stepStatuses[.installPythonDeps] = .running
        guard await installPythonDeps(repoPath: repoPath, pnlPipArgs: pnlPipArgs) else { return false }
        stepStatuses[.installPythonDeps] = .completed

        await prepareFastStart(repoPath: repoPath, pnlPipArgs: pnlPipArgs)

        appendOutput("\n✓ Environment repaired.\n")
        return true
    }

    /// Compile bytecode and build matplotlib's font cache, as a step of its
    /// own so its time is its own (#223). Never fails the install: what
    /// doesn't get done here, the first start does.
    private func prepareFastStart(repoPath: URL, pnlPipArgs: [String]) async {
        stepStatuses[.prepareFastStart] = .running
        appendOutput("Preparing Python for a fast first start...\n")
        let plan = await FastStartPrep.run(
            repoPath: repoPath,
            pnlPipArgs: pnlPipArgs,
            packagesChanged: packagesWritten,
            log: { [weak self] line in self?.appendOutput(line + "\n") },
            detail: { [weak self] detail in self?.onDetail?(.prepareFastStart, detail) })
        stepStatuses[.prepareFastStart] = plan.skipsEverything
            ? .skipped(FastStartPrep.Plan.skipReason) : .completed
    }

    /// Whether any installer run of this install wrote or removed packages
    /// (#223): the fast-start preparation recompiles bytecode only then.
    private var packagesWritten = false

    // MARK: - Application setup steps

    private func createVenv(repoPath: URL) async -> Bool {
        let backendDir = repoPath.appendingPathComponent("backend")
        let venvDir = backendDir.appendingPathComponent(".venv")

        // An existing venv is only reusable if the interpreter it was built from
        // is still the one we're about to use. A venv records that interpreter by
        // absolute path, and the bundled runtime's path carries its version
        // (Resources/python-3.14.7/) — so a Sparkle update that bumps Python
        // moves the path and silently orphans every venv. (#66)
        let existingRecord = VenvHealth.record(atVenv: venvDir)
        let currentBin = depInstaller.resolvedPythonPath.map(VenvHealth.binDirectory(ofInterpreter:))
        let recordedHomeExists = existingRecord.map {
            FileManager.default.fileExists(atPath: $0.home)
        } ?? false

        switch VenvHealth.disposition(
            record: existingRecord,
            currentInterpreterBin: currentBin,
            recordedHomeExists: recordedHomeExists
        ) {
        case .usable:
            appendOutput("  ✓ Virtual environment already exists\n")
            return true

        case .absent:
            break

        case .rebuild(let reason):
            // Say why. A ten-minute reinstall with no explanation reads as a bug.
            appendOutput("Rebuilding the virtual environment — \(reason).\n")
            appendOutput("  Python packages will be reinstalled; this takes a few minutes.\n")
            do {
                try FileManager.default.removeItem(at: venvDir)
            } catch {
                stepStatuses[.createVenv] = .failed(
                    "Couldn't remove the stale virtual environment at \(venvDir.path): "
                    + error.localizedDescription)
                return false
            }
        }

        // Use the interpreter installPython() resolved — an absolute path, which
        // may live inside a keg-only Homebrew formula that is deliberately not
        // linked into PATH. Falling back to `which` would reintroduce the reason
        // the old code force-linked the prefix. (#62)
        guard let pythonPath = depInstaller.resolvedPythonPath else {
            stepStatuses[.createVenv] = .failed(
                "No supported Python was resolved. Re-run setup, or install "
                + "\(PythonRequirement.preferredFormula) and try again."
            )
            return false
        }
        appendOutput("Using interpreter: \(pythonPath)\n")

        appendOutput("Creating virtual environment...\n")
        let result = try? await Shell.run(pythonPath, arguments: ["-m", "venv", venvDir.path], currentDirectory: backendDir)
        if let result, result.exitCode == 0 {
            appendOutput("  ✓ Virtual environment created\n")
            return true
        }
        stepStatuses[.createVenv] = .failed(result?.stderr ?? "Unknown error")
        return false
    }

    private func installPythonDeps(repoPath: URL, pnlPipArgs: [String] = ["psyneulink"]) async -> Bool {
        let venvPip = repoPath.appendingPathComponent("backend/.venv/bin/pip")
        let backendDir = repoPath.appendingPathComponent("backend")

        guard FileManager.default.fileExists(atPath: venvPip.path) else {
            stepStatuses[.installPythonDeps] = .failed("pip not found")
            return false
        }
        packagesWritten = false

        var env = Shell.userEnvironment()
        let venvDir = repoPath.appendingPathComponent("backend/.venv")
        env["VIRTUAL_ENV"] = venvDir.path
        env["PATH"] = venvDir.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "")
        // uv's cache lives with the app's data, so a repair or an update
        // reuses every wheel it has seen and fetches only new commits (#224).
        env = PsyNeuLinkInstall.environment(base: env, supportDirectory: BundledPsyNeuView.supportDirectory())

        // Prefer the bundled uv: measured cold on the same machine, interpreter
        // and backend, pip took 1032s and uv 217s. Almost all of the weight is
        // PsyNeuLink's dependency tree, and uv resolves and downloads it in
        // parallel. Falls back to pip when no uv is bundled — a developer build,
        // or if uv fails for any reason — because a slow install is much better
        // than no install. (#94)
        let installer = Shell.bundledUvPath()

        // Order matters here. `backend/pyproject.toml` depends on a bare
        // `psyneulink`, so installing it first pulls the PyPI wheel — which the
        // phase-2 override then throws away, because the default source is the
        // Princeton `devel` branch, not PyPI. That is a full PsyNeuLink download
        // wasted on essentially every install. (#115)
        //
        // When the venv has no PsyNeuLink yet, install the chosen source first.
        // The backend requirement is unpinned and phase 2 passes no `--upgrade`,
        // so both pip and uv treat it as already satisfied and leave the build
        // alone. Verified against both resolvers rather than assumed.
        //
        // The flags differ by position — `PsyNeuLinkInstall.command` says how
        // and why. Since #224 the same uv installs PsyNeuLink too, with pip
        // as the fallback: uv writes the same `direct_url.json` pip does
        // (`vcs_info` for a git URL, `dir_info.editable` for a checkout),
        // which is how the backend's Settings tell the sources apart.
        let alreadyHasPNL = VersionReport.installedVersion(of: "psyneulink", inVenv: venvDir) != nil
        let installPNLFirst = Self.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: pnlPipArgs, venvAlreadyHasPsyNeuLink: alreadyHasPNL)

        if installPNLFirst {
            let outcome = await installPsyNeuLink(
                pnlPipArgs: pnlPipArgs, position: .first,
                uvPath: installer, venvPip: venvPip, backendDir: backendDir, environment: env)
            if case .failed(let reason) = outcome {
                stepStatuses[.installPythonDeps] = .failed(
                    "Installing PsyNeuLink from the chosen source failed (\(reason))")
                return false
            }
        }

        // Phase 1: install backend deps from backend/pyproject.toml.
        // Editable so the backend stays runnable in place from the tree.
        if installer != nil {
            appendOutput("Installing Python packages with the bundled uv (a few minutes)...\n")
        } else {
            appendOutput("Installing Python packages from pyproject.toml (this may take 15+ minutes)...\n")
        }

        var backendExitCode = await runDependencyInstall(
            uvPath: installer, venvPip: venvPip, backendDir: backendDir, environment: env)

        if backendExitCode != 0, installer != nil {
            appendOutput("uv failed (exit code \(backendExitCode)) — retrying with pip.\n")
            backendExitCode = await runDependencyInstall(
                uvPath: nil, venvPip: venvPip, backendDir: backendDir, environment: env)
        }

        if backendExitCode != 0 {
            stepStatuses[.installPythonDeps] = .failed(
                "Installing the Python dependencies failed (exit code \(backendExitCode))")
            return false
        }

        // Phase 2: ensure psyneulink matches the user's chosen source. Skipped
        // when it was already installed first, above — that is the fresh-install
        // path. This remains the route for a venv that already carried a
        // PsyNeuLink (a repair, or a source change), where a force-reinstall is
        // the only way to guarantee the chosen source wins.
        if pnlPipArgs != ["psyneulink"] && !installPNLFirst {
            let outcome = await installPsyNeuLink(
                pnlPipArgs: pnlPipArgs, position: .override,
                uvPath: installer, venvPip: venvPip, backendDir: backendDir, environment: env)
            if case .failed(let reason) = outcome {
                stepStatuses[.installPythonDeps] = .failed("PsyNeuLink override install failed (\(reason))")
                return false
            }
        }

        appendOutput("  ✓ Python dependencies installed\n")
        return true
    }

    /// Install PsyNeuLink with uv, then with pip if uv couldn't (#224).
    /// Each run is timed on its own; the log says when pip takes over, and why.
    private func installPsyNeuLink(
        pnlPipArgs: [String],
        position: PsyNeuLinkInstall.Position,
        uvPath: String?,
        venvPip: URL,
        backendDir: URL,
        environment: [String: String]
    ) async -> PsyNeuLinkInstall.Outcome {
        let pipAvailable = FileManager.default.fileExists(atPath: venvPip.path)
        var tool: PsyNeuLinkInstall.Tool = uvPath != nil ? .uv : .pip
        var fellBack = false
        while true {
            let command = PsyNeuLinkInstall.command(tool: tool, pnlPipArgs: pnlPipArgs, position: position)
            let executable = tool == .uv ? (uvPath ?? venvPip.path) : venvPip.path
            appendOutput("Installing PsyNeuLink from chosen source "
                         + "(\(pnlPipArgs.joined(separator: " "))) with \(tool.name)...\n")
            beginTimeline(label: command.label, id: command.timelineID + (fellBack ? "-pip" : ""))
            let exitCode = await Shell.runStreaming(
                executable,
                arguments: command.arguments,
                currentDirectory: backendDir,
                environment: environment,
                onOutput: streamToLog()
            )
            endTimeline()
            let outcome = PsyNeuLinkInstall.outcome(exitCode: exitCode, tool: tool, pipAvailable: pipAvailable)
            guard case .retryWithPip(let reason) = outcome else { return outcome }
            appendOutput("\(reason) — retrying with pip. uv's output above says what it objected to.\n")
            tool = .pip
            fellBack = true
        }
    }

    /// Whether to install the chosen PsyNeuLink source before the backend
    /// rather than overriding it afterwards. (#115)
    ///
    /// Two conditions. The source has to be something other than plain PyPI —
    /// with `["psyneulink"]` there is nothing to override and no duplicate
    /// download to avoid. And the venv has to be free of PsyNeuLink, because the
    /// early install deliberately omits `--force-reinstall`: on a fresh venv it
    /// is redundant, and on a populated one it would be the wrong tool, since
    /// only the later override can replace an existing build without dragging
    /// its whole dependency tree along.
    nonisolated static func shouldInstallPsyNeuLinkFirst(
        pnlPipArgs: [String],
        venvAlreadyHasPsyNeuLink: Bool
    ) -> Bool {
        pnlPipArgs != ["psyneulink"] && !venvAlreadyHasPsyNeuLink
    }

    /// Run `install -e .` with uv when one is given, otherwise pip. Kept in one
    /// place so the fallback runs exactly the command the primary path would.
    private func runDependencyInstall(
        uvPath: String?,
        venvPip: URL,
        backendDir: URL,
        environment: [String: String]
    ) async -> Int32 {
        let executable = uvPath ?? venvPip.path
        let arguments = uvPath != nil
            ? ["pip", "install", "-e", "."]
            : ["install", "-e", "."]
        beginTimeline(
            label: uvPath != nil ? "Backend packages with uv" : "Backend packages with pip",
            id: uvPath != nil ? "backend" : "backend-pip")
        let exitCode = await Shell.runStreaming(
            executable,
            arguments: arguments,
            currentDirectory: backendDir,
            environment: environment,
            onOutput: streamToLog()
        )
        endTimeline()
        return exitCode
    }

    // MARK: - Timing the installers (#215)

    /// Output goes to the log as before, and to the timeline with the moment
    /// it arrived — the clock is read on the reader's thread, before the hop
    /// to the main actor, so a busy main thread can't shift a phase boundary.
    private func streamToLog() -> @Sendable (String) -> Void {
        { [weak self] text in
            let now = Date()
            Task { @MainActor [weak self] in
                self?.appendOutput(text)
                self?.feedTimeline(text, at: now)
            }
        }
    }

    private func beginTimeline(label: String, id: String) {
        timeline = InstallTimeline(label: label, id: id, startedAt: Date())
        partialLine = ""
    }

    /// pip and uv write in chunks; a phase marker can arrive split across two.
    /// pip's progress bars also end lines with a carriage return.
    private func feedTimeline(_ text: String, at now: Date) {
        guard timeline != nil else { return }
        var buffer = partialLine + text
        partialLine = ""
        while let end = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<end])
            buffer = String(buffer[buffer.index(after: end)...])
            timeline?.observe(line, at: now)
        }
        partialLine = buffer
    }

    private func endTimeline() {
        guard var done = timeline else { return }
        let now = Date()
        if !partialLine.isEmpty { done.observe(partialLine, at: now) }
        done.finish(at: now)
        timeline = nil
        partialLine = ""
        if done.wrotePackages { packagesWritten = true }
        appendOutput(Self.summary(of: done) + "\n")
        for detail in done.details() { onDetail?(.installPythonDeps, detail) }
    }

    /// One log line that says where the time went:
    /// "PsyNeuLink (…) with pip: 240.1 s — fetch the source (git clone) 12.0 s, …
    /// (310.2 MB: torch 73.9 MB, …)".
    nonisolated static func summary(of t: InstallTimeline) -> String {
        var parts = t.entries.map { e -> String in
            var s = String(format: "%@ %.1f s", e.phase.title, e.seconds)
            if let p = e.packages { s += " (\(p) packages)" }
            return s
        }
        if t.totalBytes > 0 {
            parts.append("\(InstallTimeline.format(bytes: t.totalBytes)) downloaded: \(t.largestDownloads())")
        }
        let total = t.totalSeconds.map { String(format: "%.1f s", $0) } ?? "unfinished"
        return "  \(t.label): \(total)" + (parts.isEmpty ? "" : " — " + parts.joined(separator: ", "))
    }

    private func installNodeDeps(repoPath: URL) async -> Bool {
        let frontendDir = repoPath.appendingPathComponent("frontend")

        guard let npmPath = await Shell.which("npm") else {
            stepStatuses[.installNodeDeps] = .failed("npm not found")
            return false
        }

        appendOutput("Installing Node.js packages...\n")

        let exitCode = await Shell.runStreaming(
            npmPath,
            arguments: ["install"],
            currentDirectory: frontendDir,
            onOutput: { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.appendOutput(text)
                }
            }
        )

        if exitCode == 0 {
            appendOutput("  ✓ Node.js dependencies installed\n")
            return true
        }
        stepStatuses[.installNodeDeps] = .failed("npm install failed (exit code \(exitCode))")
        return false
    }

    private func buildFrontend(repoPath: URL) async -> Bool {
        let frontendDir = repoPath.appendingPathComponent("frontend")

        // Use vite build directly instead of `npm run build` (which runs `tsc -b && vite build`).
        // tsc strict type checking fails on import.meta.env which is a Vite-specific feature.
        // vite build handles TypeScript transpilation correctly without the strict check.
        let vitePath = frontendDir.appendingPathComponent("node_modules/.bin/vite").path

        guard FileManager.default.fileExists(atPath: vitePath) else {
            stepStatuses[.buildFrontend] = .failed("vite not found in node_modules")
            return false
        }

        appendOutput("Building production frontend...\n")

        let exitCode = await Shell.runStreaming(
            "/usr/bin/env",
            arguments: ["node", vitePath, "build"],
            currentDirectory: frontendDir,
            onOutput: { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.appendOutput(text)
                }
            }
        )

        if exitCode == 0 {
            let distIndex = frontendDir.appendingPathComponent("dist/index.html")
            if FileManager.default.fileExists(atPath: distIndex.path) {
                appendOutput("  ✓ Frontend built\n")
                return true
            }
            stepStatuses[.buildFrontend] = .failed("Build completed but dist/index.html not found")
            return false
        }
        stepStatuses[.buildFrontend] = .failed("npm run build failed (exit code \(exitCode))")
        return false
    }

    // MARK: - Output

    private func appendOutput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentOutput += trimmed + "\n"
        onOutput?(trimmed)
    }
}
