import Foundation

@MainActor
final class ProcessManager {
    private var backendProcess: Process?
    private let appState: AppState
    private let healthChecker: HealthChecker
    private let logCollector: LogCollector
    var autoRestart: Bool = false
    /// Install-time preferences published to the backend at uvicorn launch
    /// so /api/settings/info can serve the Mac app's view (issue #10).
    var preferences: Preferences?
    var onServiceReady: (() -> Void)?
    /// Called when the backend never becomes healthy, so the UI can say so
    /// rather than spinning indefinitely. (#96)
    /// Whether the backend process is still alive.
    ///
    /// The distinction the retry button needed: a process that has exited is
    /// not coming back on its own, so trying again cannot help (#104).
    var isBackendRunning: Bool {
        backendProcess?.isRunning ?? false
    }

    /// When the current start attempt began, for the boot measurement (#104).
    private var startAttemptBegan: Date?

    var onServiceFailed: ((String) -> Void)?
    /// Called while the backend is still starting and taking a while, so the UI
    /// can show progress instead of appearing to hang. (#101)
    var onServiceWaiting: ((TimeInterval) -> Void)?
    /// Called the moment the backend answers /health, with how long that
    /// took, before the boot report is written — so the checklist can note it
    /// as a timed part of "Start the server" (#215).
    var onServerHealthy: ((TimeInterval) -> Void)?
    /// Called for each phase of its start the backend reports on its
    /// standard output (#232), with the moment the line arrived — read on the
    /// pipe's thread, before the hop to the main actor, so a busy main thread
    /// can't shift a step boundary.
    var onStartPhase: ((StartPhase, Date) -> Void)?
    /// The launch step by step, for the boot report (#215): the app's
    /// checklist, asked for when the report is written.
    var bootSteps: (() -> [BootReport.StepTiming])?
    private var repoPath: URL?
    private var didNotifyReady = false
    /// The backend's standard output, split into lines across chunks (#232).
    private var stdoutLines = LineSplitter()

    /// Hand each phase line in a chunk of backend output to `onStartPhase`.
    private func readStartPhases(from chunk: String, at now: Date) {
        for line in stdoutLines.lines(from: chunk) {
            if let phase = StartPhase.parse(line) {
                onStartPhase?(phase, now)
            }
        }
    }

    init(appState: AppState, healthChecker: HealthChecker, logCollector: LogCollector) {
        self.appState = appState
        self.healthChecker = healthChecker
        self.logCollector = logCollector
    }

    /// Write the test app's own project folder into its settings file, when
    /// `AppIdentity.projectFolderSeed` says to (#240). Returns the line for
    /// the launch log; nil when nothing changed. The real app never writes.
    nonisolated static func seedProjectFolder(identity: AppIdentity) -> String? {
        let file = identity.configFile()
        // A file that is there but can't be read is left alone, never replaced.
        let exists = FileManager.default.fileExists(atPath: file.path)
        let existing = try? Data(contentsOf: file)
        if exists && existing == nil { return nil }
        guard let seed = identity.projectFolderSeed(existing: existing) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try seed.settings.write(to: file, options: .atomic)
            return seed.note
        } catch {
            return "Couldn't set the test app's own project folder in \(file.path): "
                + error.localizedDescription
        }
    }

    /// The environment the backend is launched with.
    ///
    /// Pure so it can be asserted on: what this publishes is the backend's only
    /// account of where it is running, and getting it wrong is silent -- the
    /// backend just believes something else and behaves accordingly (#59).
    nonisolated static func backendEnvironment(
        base: [String: String],
        repoPath: URL,
        identity: AppIdentity = .current
    ) -> [String: String] {
        var env = base

        // Activate the venv.
        let venvDir = repoPath.appendingPathComponent("backend/.venv")
        env["VIRTUAL_ENV"] = venvDir.path
        env["PATH"] = venvDir.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "")

        // The models folder is deliberately NOT set here any more (#212).
        //
        // Through 0.5.16 this published `PSYNEWVIEW_MODELS_DIR` as
        // `~/.psyneuview/models:<tree>/models`, so Save As never wrote inside
        // the included copy's folder, which updates replace (PsyNeuView-archive#1089).
        // PsyNeuView 0.5.10 owns that decision itself (PsyNeuView-archive#1295): in
        // mac_app mode its default is a visible `~/Documents/PsyNeuView-My-Models`
        // for a new install, a legacy folder (`~/.psyneuview/models`) when one
        // already holds models — with a one-time offer to move — and Settings
        // has Move… at any time. The environment variable wins over all of that,
        // so while the app set it the folder was fixed: no Move…, no offer, no
        // visible default.
        //
        // The included tree's own `models/` can't become the default by
        // accident: `rescueUserModels` empties it of `.py` files before every
        // start from an app-owned tree, and the backend only falls back to a
        // legacy folder that actually holds models.
        //
        // A developer who exports the variable still gets it: `base` is the
        // inherited environment, and nothing here removes it.

        // Say who launched the backend (#59).
        //
        // The backend has had four deployment modes since #1062, selected by
        // this variable, and this app never set it -- so the backend has always
        // believed it was a plain local install and every mac_app branch has
        // been dead code in production.
        //
        // What that actually cost: the Settings panel picks which keyboard
        // chords it will let you bind from the reported mode, because a
        // WKWebView receives chords (Cmd+W among them) that a browser keeps for
        // itself. Reading "local" inside the Mac app, it applied browser rules
        // and refused bindings that would in fact have worked.
        //
        // Capabilities are unchanged by this: mac_app and local both allow
        // install and host GitHub credentials, and neither is remote. The 409
        // that once told Mac-app users to go to Preferences was retired in #132,
        // so declaring the mode no longer re-enables a guard -- it just stops
        // the backend from misreporting where it is running.
        env["PSYNEUVIEW_DEPLOYMENT_MODE"] = "mac_app"

        // Which app this is (#209): `PSYNEUVIEW_APP_FLAVOR=release|test`
        // for both, and for the test app its own settings file, PsyNeuLink
        // clones, working copies and layouts, so a test never touches the
        // real app's. The real app sets none of the paths: PsyNeuView's own
        // defaults are what every existing install already uses.
        for (key, value) in identity.backendOverrides() {
            env[key] = value
        }

        // The backend reports the phases of its start on standard output
        // (#232), and the app reads them as they happen. Python block-buffers
        // stdout when it is a pipe, which would hand the app the whole start
        // in one lump at exit; unbuffered, each line arrives as it is printed.
        env["PYTHONUNBUFFERED"] = "1"

        // The PsyNeuLink source is deliberately *not* published here any more
        // (#132, was #10).
        //
        // These variables told the backend what the app intended, and
        // `settings_info._override_from_env` reported that back to the gear
        // panel as fact. Once the source can also be changed from the gear
        // icon, the app's intent is no longer the truth — the panel would show
        // the app's stale value while a different PsyNeuLink was installed.
        //
        // The backend introspects the package instead, which is what it already
        // does for the version.

        return env
    }

    // MARK: - Start

    func startAll(repoPath: URL) async {
        guard appState.canStart else {
            logCollector.add("Cannot start: server is not in stopped state", source: .system)
            return
        }

        self.repoPath = repoPath
        didNotifyReady = false

        // The port from last time when it's free, so the page keeps the same
        // origin and so its localStorage (#218); otherwise a free one.
        let remembered = PortChecker.rememberedPort()
        let backendPort = PortChecker.choosePort(
            remembered: remembered, isFree: PortChecker.isFree, findFree: PortChecker.findFreePort)

        guard backendPort > 0 else {
            logCollector.add("Failed to find a free port", source: .system, isError: true)
            appState.backendStatus = .error
            return
        }
        if let remembered, remembered != backendPort {
            logCollector.add(
                "Port \(remembered) from last time is in use; using \(backendPort) instead.",
                source: .system)
        }
        PortChecker.remember(backendPort)

        appState.backendPort = backendPort
        logCollector.add("Starting PsyNeuView on port \(backendPort)...", source: .system)

        do {
            try startBackend(repoPath: repoPath)
        } catch {
            logCollector.add("Failed to start: \(error.localizedDescription)", source: .system, isError: true)
            appState.backendStatus = .error
        }
    }

    private func startBackend(repoPath: URL) throws {
        appState.backendStatus = .starting

        let venvPython = repoPath
            .appendingPathComponent("backend/.venv/bin/python")

        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            logCollector.add(
                "Python venv not found at \(venvPython.path). Run the Setup Wizard to install dependencies.",
                source: .system, isError: true
            )
            appState.backendStatus = .error
            return
        }

        // Verify the production frontend build exists
        let distIndex = repoPath.appendingPathComponent("frontend/dist/index.html")
        if !FileManager.default.fileExists(atPath: distIndex.path) {
            logCollector.add(
                "Production frontend build not found. Run the Setup Wizard to rebuild.",
                source: .system, isError: true
            )
            appState.backendStatus = .error
            return
        }

        // The backend chooses and creates the models folder itself (#212); the
        // app no longer makes `~/.psyneuview/models` ahead of it. An empty
        // legacy folder would be harmless (the backend only keeps one that
        // holds models), but it is also pointless.
        // The test app's project folder is its own, not the real app's (#240).
        if let note = Self.seedProjectFolder(identity: .current) {
            logCollector.add(note, source: .system)
        }

        let env = Self.backendEnvironment(
            base: Shell.userEnvironment(),
            repoPath: repoPath,
            identity: .current
        )

        let logCollector = self.logCollector
        stdoutLines = LineSplitter()

        let process = try Shell.launch(
            executablePath: venvPython.path,
            arguments: [
                "-m", "uvicorn", "app.main:app",
                "--port", String(appState.backendPort),
            ] + (preferences?.developerMode == true ? ["--reload"] : []),
            currentDirectory: repoPath.appendingPathComponent("backend"),
            environment: env,
            onStdout: { [weak self] text in
                // The clock is read here, on the pipe's thread (#232).
                let now = Date()
                let trimmed = text.trimmingCharacters(in: .newlines)
                Task { @MainActor [weak self] in
                    logCollector.add(trimmed, source: .backend)
                    self?.readStartPhases(from: text, at: now)
                }
            },
            onStderr: { text in
                let trimmed = text.trimmingCharacters(in: .newlines)
                Task { @MainActor in
                    logCollector.add(trimmed, source: .backend)
                }
            },
            onTermination: { [weak self] exitCode in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.backendProcess = nil
                    if self.appState.backendStatus != .stopping {
                        self.logCollector.add(
                            "Server exited unexpectedly (code \(exitCode))",
                            source: .system, isError: true
                        )
                        self.appState.backendStatus = .error
                        self.attemptAutoRestart()
                    } else {
                        self.appState.backendStatus = .stopped
                    }
                }
            }
        )

        backendProcess = process

        // Poll the health endpoint — once it responds, the server is ready
        // (both API and frontend are served from this single server)
        startAttemptBegan = Date()
        healthChecker.startPollingBackend(
            port: appState.backendPort,
            onWaiting: { [weak self] elapsed in self?.onServiceWaiting?(elapsed) }
        ) { [weak self] success in
            guard let self else { return }
            if success {
                self.appState.backendStatus = .running
                self.logCollector.add("Server is ready", source: .system)
                if let began = self.startAttemptBegan {
                    self.onServerHealthy?(Date().timeIntervalSince(began))
                }
                self.reportBoot(healthy: true)
                self.notifyReady()
            } else if self.appState.backendStatus == .starting {
                let message = "The PsyNeuView server didn't start within "
                    + "\(Int(Constants.healthTimeout / 60)) minutes."
                self.logCollector.add("Server health check timed out", source: .system, isError: true)
                self.appState.backendStatus = .error
                self.reportBoot(healthy: false)
                self.onServiceFailed?(message)
            }
        }
    }

    // MARK: - Stop

    func stopAll() {
        logCollector.add("Stopping PsyNeuView...", source: .system)
        healthChecker.stopPolling()

        if let process = backendProcess {
            appState.backendStatus = .stopping
            Shell.killProcessTree(process)
        } else {
            appState.backendStatus = .stopped
        }

        // Fallback: kill by port after a short delay
        Task {
            try? await Task.sleep(for: .seconds(1))
            if appState.backendStatus == .stopping {
                await Shell.killPort(appState.backendPort)
                appState.backendStatus = .stopped
            }
            logCollector.add("Server stopped", source: .system)
        }
    }

    // MARK: - Restart

    func restartAll(repoPath: URL) async {
        stopAll()
        try? await Task.sleep(for: .seconds(2))
        await startAll(repoPath: repoPath)
    }

    // MARK: - Ready

    /// Record how long this start took, when a report was asked for (#104).
    ///
    /// A ceiling is only meaningful next to a measurement. 0.5.3 shipped a 30s
    /// ceiling against a 38.67s warm-up and nothing objected, because the tests
    /// compared one constant to another.
    ///
    /// Writes only when `PSYNEUVIEW_BOOT_REPORT` names a path, so a normal
    /// launch is untouched. Logs the summary either way — it costs nothing and
    /// is useful in a support report.
    private func reportBoot(healthy: Bool) {
        guard let began = startAttemptBegan else { return }
        let measurement = BootReport.Measurement(
            seconds: Date().timeIntervalSince(began),
            ceiling: Constants.healthTimeout,
            healthy: healthy,
            steps: bootSteps?())
        logCollector.add(BootReport.summary(measurement), source: .system)
        BootReport.write(measurement)
    }

    /// Open the window the moment /health answers (#226).
    ///
    /// This used to wait a fixed 3 s first, "to give the warm worker time to
    /// import PsyNeuLink". The backend's lifespan has since started that
    /// worker itself and waited for its ready signal before uvicorn accepts
    /// a connection (`main.py`: `_get_warm_worker()` in `lifespan`, whose
    /// `WarmWorker.__init__` blocks on `###READY###`), so /health answering
    /// already means the worker is warm. The 3 s were dead time on every
    /// launch; nothing is left to wait for.
    private func notifyReady() {
        guard !didNotifyReady else { return }
        didNotifyReady = true
        logCollector.add("Opening PsyNeuView window", source: .system)
        onServiceReady?()
    }

    // MARK: - Auto-Restart

    private func attemptAutoRestart() {
        guard autoRestart, let repoPath else { return }
        logCollector.add("Auto-restarting in 3 seconds...", source: .system)
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard autoRestart else { return }
            logCollector.add("Auto-restarting...", source: .system)
            stopAll()
            try? await Task.sleep(for: .seconds(1))
            await startAll(repoPath: repoPath)
        }
    }

    // MARK: - Cleanup

    func stopAllSync() {
        healthChecker.stopPolling()
        if let process = backendProcess, process.isRunning {
            Shell.killProcessTree(process)
        }
    }
}
