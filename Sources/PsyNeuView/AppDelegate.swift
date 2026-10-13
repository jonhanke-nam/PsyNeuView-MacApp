import AppKit
import Sparkle
import SwiftUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var devMenu: NSMenu!
    private var viewMenu: NSMenu?
    /// The two App-menu update items, retitled each time the menu opens so
    /// each shows what it acts on. (#167)
    private var appUpdateItem: NSMenuItem?
    private var codeUpdateItem: NSMenuItem?
    /// The checkout item is a developer item (#214): it and its "Developer"
    /// header and separator are hidden together outside developer mode.
    private var codeUpdateDeveloperItems: [NSMenuItem] = []
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenu!
    private var appWindows: [NSWindow] = []
    private var logWindow: NSWindow?
    private var setupWindow: NSWindow?

    let appState = AppState()
    let preferences = Preferences()
    /// The app's side of the `pnvSettings` bridge (#200), shared by every
    /// app window.
    private var settingsHost: AppSettingsHost!
    /// The page's own preferences, kept across launches (#218), shared by
    /// every app window.
    private var pagePreferences: PagePreferencesStore!
    /// Report a Problem (#202), shown in the Logs window.
    let problemReport = ProblemReportModel()
    /// How this launch's start went, for the report: "started in 38.2 s", or
    /// the failure the starting window showed.
    private var lastStartupOutcome: String?
    /// The last start's checklist (#196), kept for the report after the
    /// starting window lets go of it.
    private var reportProgress: InstallProgress?
    private var healthChecker: HealthChecker!
    private var logCollector: LogCollector!
    /// When this launch began, for the report: a short launch means the
    /// previous launch's log is attached too (#208).
    private let launchDate = Date()
    /// This launch's log file (#208).
    private var launchLog: LaunchLogWriter!
    private var processManager: ProcessManager!
    private var updater: Updater!
    /// The folder this launch moved away from (#186), set only by a move and
    /// cleared once the server answers: then the older included folders are
    /// removed, keeping this one as the fallback (#239).
    private var pendingBundledCleanup: URL?

    /// Sparkle auto-updater for the Mac app itself.
    /// Checks for new DMG releases via the appcast.
    ///
    /// Not started in the test app (#209): its Info.plist has no feed, and an
    /// update would replace a test build with a release under the test name.
    private lazy var sparkleUpdater: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: AppIdentity.current.updatesEnabled,
            updaterDelegate: appUpdateObserver, userDriverDelegate: nil)
    }()

    /// Hears what Sparkle's checks find, so the page can say an update is
    /// waiting (#6). Kept here: Sparkle holds its delegate weakly.
    private let appUpdateObserver = AppUpdateObserver()

    // Tracks whether the setup wizard completed successfully (user clicked Launch)
    private var setupCompleted = false

    // Observation token for state changes
    private var stateObservation: Any?

    /// Ask about moving to /Applications before any other startup work.
    ///
    /// Deliberately first: setup would otherwise build a large Python
    /// environment pinned to a path the user is about to eject or move. (#109)
    private func offerToMoveToApplicationsIfNeeded() {
        let location = AppRelocation.classify(bundlePath: Bundle.main.bundlePath)
        guard let prompt = AppRelocation.prompt(for: location) else { return }

        // Nobody is there to answer. Take the same choice declining would, and
        // say so in the log rather than silently.
        if AppRelocation.isNonInteractive {
            logCollector.add(
                "Not offering to move the app (PSYNEUVIEW_NONINTERACTIVE) — "
                + "continuing from \(Bundle.main.bundlePath).",
                source: .system)
            return
        }

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Continue Without Moving")

        guard alert.runModal() == .alertFirstButtonReturn else {
            logCollector.add(
                "Continuing from \(Bundle.main.bundlePath) — the Python environment "
                + "will need rebuilding if the app moves later.",
                source: .system)
            return
        }

        do {
            let moved = try AppRelocation.moveToApplications(from: Bundle.main.bundlePath)
            AppRelocation.relaunch(at: moved)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move PsyNeuView"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.addButton(withTitle: "Continue Anyway")
            failure.runModal()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Resolve the app's toolchain PATH early
        _ = Shell.toolchainPath()

        // Initialize services
        healthChecker = HealthChecker()
        logCollector = LogCollector(appState: appState)
        launchLog = LaunchLogWriter(date: launchDate)
        logCollector.launchLog = launchLog
        if let failure = launchLog.failure {
            logCollector.add(failure, source: .system, isError: true)
        }
        processManager = ProcessManager(
            appState: appState,
            healthChecker: healthChecker,
            logCollector: logCollector
        )

        // Sync preferences to state
        appState.repoPath = preferences.repoPath
        processManager.autoRestart = preferences.autoRestart
        processManager.preferences = preferences
        updater = Updater(logCollector: logCollector, preferences: preferences, appState: appState)
        settingsHost = AppSettingsHost(preferences: preferences)
        pagePreferences = PagePreferencesStore()
        settingsHost.onAutoRestartChanged = { [weak self] on in self?.processManager.autoRestart = on }
        settingsHost.onDeveloperModeChanged = { [weak self] _ in self?.refreshCodeUpdateVisibility() }
        settingsHost.onSwitchInstall = { [weak self] decision in self?.switchInstall(decision) }
        settingsHost.onInstallAppUpdate = { [weak self] in self?.sparkleUpdater.checkForUpdates(nil) }
        settingsHost.onSyncPsyNeuLinkSource = { [weak self] in
            guard let self else { return }
            self.reconcilePsyNeuLinkRecord(repoPath: self.appState.repoPath ?? self.preferences.repoPath)
        }
        appUpdateObserver.onChange = { [weak self] found in
            guard let self, let host = self.settingsHost else { return }
            MainActor.assumeIsolated {
                guard host.foundAppUpdate != found else { return }
                host.foundAppUpdate = found
                // Every open window's page hears it, as after any setting change.
                NotificationCenter.default.post(
                    name: SettingsBridge.didChange, object: nil,
                    userInfo: ["snapshot": SettingsBridge.snapshot(host)])
            }
        }
        pagePreferences.log = { [weak self] line in self?.logCollector.add(line, source: .system) }
        configureProblemReport()

        // Offer to relocate only now that the services exist.
        //
        // This used to be the first line of this method, before logCollector
        // was assigned — and the decline branch logs, so declining the prompt
        // crashed the app on an implicitly-unwrapped nil (#136). The accept
        // branch relaunches, so it never touched the nil, which is why the bug
        // survived: the path that works is the path that got exercised.
        //
        // Nothing in the prompt needs to run before the toolchain path
        // resolves, so later is simply correct rather than a workaround.
        offerToMoveToApplicationsIfNeeded()

        // The launch step by step, for the boot report and Report a Problem
        // (#215): the checklist's times, and when the server first answered.
        processManager.bootSteps = { [weak self] in
            self?.reportProgress?.bootTimings() ?? []
        }
        processManager.onServerHealthy = { [weak self] seconds in
            self?.startupProgress?.note(
                InstallProgress.Detail(id: "health", title: "Server answered /health", seconds: seconds, bytes: nil),
                under: .startServer)
            // Whatever server step is still running is done; ones a backend
            // without phase lines never reported are said to be (#232).
            self?.startupProgress?.serverAnsweredHealth()
        }
        // The server's own start, phase by phase (#232): "Loading PsyNeuLink"
        // and "Warming up the model runner" are real steps with their own
        // clocks on a backend that reports them.
        processManager.onStartPhase = { [weak self] phase, at in
            self?.startupProgress?.apply(phase, at: at)
        }

        // Show app window when both services are ready
        processManager.onServiceReady = { [weak self] in
            if let self, let startedAt = self.servicesStartedAt {
                self.lastStartupOutcome = String(
                    format: "started in %.1f s", Date().timeIntervalSince(startedAt))
            }
            self?.startupProgress?.serverAnsweredHealth()
            self?.startupProgress = nil
            self?.showAppWindow()
            // #239: only after a move, and only once the new version answered.
            self?.removeOlderIncludedVersions()
            // #116: ask the backend how stale the installed PsyNeuLink is, and
            // offer to refresh it. Deliberately after the window is up and on
            // its own task — startup must never wait on GitHub, and a network
            // that is slow or absent should cost nothing but a missing prompt.
            self?.offerPsyNeuLinkUpdateIfBehind()
        }
        // Both of these now ask StartupDecision what should be on screen rather
        // than deciding here (#104). The rules that used to live in these two
        // closures — and in ProcessManager and HealthChecker — are one function
        // with a truth table, so the sequence can be tested.
        processManager.onServiceFailed = { [weak self] _ in
            guard let self else { return }
            self.applyStartupScreen(elapsed: self.elapsedSinceStart,
                                    backendRunning: self.processManager.isBackendRunning)
        }
        processManager.onServiceWaiting = { [weak self] elapsed in
            self?.applyStartupScreen(elapsed: elapsed, backendRunning: true)
        }

        // Set up the application menu bar
        setupMainMenu()

        // Set up menubar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenubarIcon()

        statusMenu = StatusMenu(appState: appState, appDelegate: self)
        statusItem.menu = statusMenu.nsMenu

        // Observe state changes to update the menubar icon and menu
        // Use a timer since @Observable doesn't bridge directly to AppKit
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onStateChanged()
            }
        }

        logCollector.add("PsyNeuView launcher started", source: .system)

        if preferences.repoPath == nil {
            if UnattendedSetup.shouldInstall(
                setupCompleted: false,
                nonInteractive: AppRelocation.isNonInteractive,
                useBundledApp: preferences.useBundledApp,
                hasBundledArchive: BundledPsyNeuView.archiveURL() != nil
            ) {
                logCollector.add(
                    "No setup yet, and nobody to answer the wizard (PSYNEUVIEW_NONINTERACTIVE) — "
                    + "installing the bundled PsyNeuView with the default choices.",
                    source: .system)
                beginProgress(ProgressPlan.steps(for: .bundledSetup, thenStart: true))
                showStartingWindow(status: "Installing PsyNeuView…")
                Task { @MainActor [weak self] in await self?.runUnattendedSetup() }
            } else {
                logCollector.add("No repo path configured. Showing setup wizard.", source: .system)
                showSetupWizard()
            }
        } else {
            // Already configured — check for updates, then start
            setupCompleted = true
            let repoPath = preferences.repoPath!
            logCollector.add("Repo path: \(repoPath.path)", source: .system)
            // In plain words, so a support log says which install ran (#195).
            logCollector.add("Running \(InstallSwitch.describeRunning(repoPath)).", source: .system)
            // Not the log window: every launch has the same wait for the backend
            // to boot and PsyNeuLink to import. (#96)
            showStartingWindow()

            Task {
                // Only a git checkout can be pulled. A bundled install gets new
                // code with the app itself, via Sparkle. (#87)
                guard Updater.tracksUpdatesWithGit(repoPath: repoPath) else {
                    logCollector.add(
                        "PsyNeuView is bundled with this app — code updates arrive with app updates.",
                        source: .system)
                    await startBundled(from: repoPath)
                    return
                }

                // A checkout start, step by step (#232): pull, then only the
                // refreshes the pull made necessary, then the server. The
                // checklist is on screen from the first step, and a step
                // not needed says so rather than disappearing.
                beginProgress(ProgressPlan.steps(for: .checkoutStart))
                let refreshed = await updater.update(repoPath: repoPath, progress: startupProgress)
                if !refreshed {
                    logCollector.add(
                        "A refresh step failed; starting with what is on disk. "
                        + "Show Logs has the details.", source: .system, isError: true)
                }
                startServices()
            }
        }
    }

    /// Offer to refresh PsyNeuLink when the install has fallen behind its branch. (#116)
    ///
    /// The app installs from the Princeton `devel` branch, which reads as
    /// "track the latest developer version" but is resolved once, at install.
    /// One 0.5.5 install was running a PsyNeuLink older than the then-current
    /// PyPI release while Settings cheerfully reported `devel`.
    ///
    /// This offers rather than acts. Silently re-pulling a moving branch at
    /// launch would mean two runs of the same app version behaving differently,
    /// which cuts against the point of bundling everything in the first place.
    func offerPsyNeuLinkUpdateIfBehind() {
        guard let repoPath = preferences.repoPath else { return }
        let port = appState.backendPort
        guard port > 0 else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await PsyNeuLinkFreshnessCheck.fetch(port: port)
            guard let report else { return }  // unreachable backend or GitHub: say nothing

            let offer = PsyNeuLinkUpdateOffer.decide(
                status: report.status,
                behindBy: report.behindBy,
                headDate: report.headDate,
                suppressed: self.preferences.pnlUpdateOffersMuted
            )
            guard case let .offer(behindBy, headDate) = offer else {
                self.logCollector.add(
                    "PsyNeuLink freshness: \(report.detail)", source: .system)
                return
            }

            let alert = NSAlert()
            alert.messageText = "A newer PsyNeuLink is available"
            alert.informativeText = PsyNeuLinkUpdateOffer.message(
                behindBy: behindBy,
                branch: self.preferences.pnlBranch,
                headDate: headDate
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Update now")
            alert.addButton(withTitle: "Not now")
            alert.addButton(withTitle: "Don't ask again")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                self.updatePsyNeuLinkNow(repoPath: repoPath)
            case .alertThirdButtonReturn:
                self.preferences.pnlUpdateOffersMuted = true
                self.logCollector.add(
                    "PsyNeuLink update offers muted. Settings still shows how far "
                    + "behind the install is.", source: .system)
            default:
                break  // Not now: ask again next launch.
            }
        }
    }

    /// Re-install PsyNeuLink from the selected source, then restart the services.
    private func updatePsyNeuLinkNow(repoPath: URL) {
        showLogWindow()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.processManager.stopAll()
            try? await Task.sleep(for: .seconds(2))

            let updated = await self.updater.upgradePsyNeuLink(repoPath: repoPath)
            if !updated {
                // The user asked for this, so a failure has to be visible rather
                // than a line in a log they were not watching.
                let failure = NSAlert()
                failure.messageText = "PsyNeuLink could not be updated"
                failure.informativeText =
                    "The install was left as it was. The log window shows what "
                    + "pip reported."
                failure.alertStyle = .warning
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
            for window in self.appWindows { window.close() }
            self.appWindows.removeAll()
            self.startServices()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        processManager.stopAllSync()
    }

    // MARK: - View menu (#178)

    @objc func zoomIn() { WindowZoom.store(WindowZoom.zoomedIn(WindowZoom.stored())) }
    @objc func zoomOut() { WindowZoom.store(WindowZoom.zoomedOut(WindowZoom.stored())) }
    @objc func zoomActualSize() { WindowZoom.store(WindowZoom.reset) }

    /// "Actual Size (125%)" while zoomed, so the menu says where you are.
    private func refreshViewMenu(_ menu: NSMenu) {
        let level = WindowZoom.stored()
        for item in menu.items where item.action == #selector(zoomActualSize) {
            item.title = level == WindowZoom.reset
                ? "Actual Size" : "Actual Size (\(WindowZoom.percentLabel(level)))"
        }
    }

    // MARK: - Main Menu Bar

    /// Add a menu item whose key equivalent comes from MenuShortcuts (#123),
    /// so the declared bindings and the real menu cannot drift apart.
    @discardableResult
    private func addItem(
        to menu: NSMenu, title: String, action: Selector?,
        binding: MenuShortcuts.Binding? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(
            withTitle: title, action: action, keyEquivalent: binding?.key ?? "")
        if let binding, binding.modifiers != .command {
            item.keyEquivalentModifierMask = binding.modifiers
        }
        return item
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppIdentity.current.displayName)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        // The two update items. They act on different things — Sparkle replaces
        // the application, the other pulls the checkout the application runs —
        // and under the same word they read as one offer, which is how an
        // afternoon went into "the update menu doesn't update". Each says what
        // it is at, filled in when the menu opens. (#167)
        let appUpdateItem = NSMenuItem(title: UpdateMenuTitles.appUpdateBase, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        appUpdateItem.target = sparkleUpdater
        // The test app has no updates (#209): the item stays, greyed out and
        // saying so, rather than vanishing and leaving the tester to wonder.
        if !AppIdentity.current.updatesEnabled {
            appUpdateItem.action = nil
            appUpdateItem.isEnabled = false
        }
        appMenu.addItem(appUpdateItem)
        self.appUpdateItem = appUpdateItem
        // Retitled on open, never rebuilt. Items created inside
        // `menuNeedsUpdate` do not exist until the menu has been opened once,
        // and a key equivalent can only fire if its item exists — which is how
        // Cmd+B came to do nothing (#75).
        appMenu.delegate = self
        // Opens PsyNeuView's own Settings in the app window (#200).
        addItem(to: appMenu, title: "Settings…", action: #selector(showSettings), binding: MenuShortcuts.settings)

        // The checkout update is a developer item (#214): checkouts are pulled
        // at every launch, so it only matters mid-session to someone working
        // in one, and everyone else saw a greyed-out item they could neither
        // use nor explain. Marked the way the Development menu marks its
        // developer-only entries — a "Developer" header after a separator —
        // and hidden with them outside developer mode. Hidden, not rebuilt,
        // for the same reason as above: the item must exist for ⌘U to work.
        let developerSeparator = NSMenuItem.separator()
        appMenu.addItem(developerSeparator)
        let developerHeader = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        developerHeader.isEnabled = false
        appMenu.addItem(developerHeader)
        let codeUpdateItem = addItem(
            to: appMenu, title: UpdateMenuTitles.codeUpdateBase,
            action: #selector(checkForUpdates), binding: MenuShortcuts.updateCode)
        self.codeUpdateItem = codeUpdateItem
        codeUpdateDeveloperItems = [developerSeparator, developerHeader, codeUpdateItem]
        refreshCodeUpdateVisibility()

        appMenu.addItem(.separator())
        addItem(to: appMenu, title: "Quit PsyNeuView", action: #selector(quitApp), binding: MenuShortcuts.quit)
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        addItem(to: fileMenu, title: "New Window", action: #selector(showAppWindow), binding: MenuShortcuts.newWindow)
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "Close Window", action: #selector(NSWindow.performClose(_:)), binding: MenuShortcuts.closeWindow)
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu. The app had none, so Cut/Copy/Paste/Select All appeared
        // nowhere a Mac user looks for them — and Cmd+X was worse than missing,
        // because the Services menu had claimed it (#123).
        //
        // nil targets on purpose: these travel the responder chain to whatever
        // is focused, which for us is the WKWebView. Hard-wiring them to a
        // target would break the moment focus moved.
        // No Undo/Redo here, deliberately. PsyNeuView implements undo across the
        // whole model — source, nodes, edges, layout — in its own history store,
        // and takes over Cmd+Z inside the code editor on purpose. A menu item
        // would match the key first and hand it to the web view as *text* undo,
        // which would silently replace model undo with something much smaller.
        let editMenu = NSMenu(title: "Edit")
        addItem(to: editMenu, title: "Cut", action: #selector(NSText.cut(_:)), binding: MenuShortcuts.cut)
        addItem(to: editMenu, title: "Copy", action: #selector(NSText.copy(_:)), binding: MenuShortcuts.copy)
        addItem(to: editMenu, title: "Paste", action: #selector(NSText.paste(_:)), binding: MenuShortcuts.paste)
        addItem(to: editMenu, title: "Select All",
                action: #selector(NSText.selectAll(_:)), binding: MenuShortcuts.selectAll)
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu: zoom the whole app window (#178). Everything in it is web
        // content, so one page zoom enlarges the toolbar, panels and tutorial
        // bar together. The About window keeps its own zoom: its key monitor
        // sees these keys first while it is the key window.
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self
        addItem(to: viewMenu, title: "Actual Size", action: #selector(zoomActualSize), binding: MenuShortcuts.actualSize)
        addItem(to: viewMenu, title: "Zoom In", action: #selector(zoomIn), binding: MenuShortcuts.zoomIn)
        // ⌘= as well, hidden: the same physical key as ⌘+ without Shift.
        let unshifted = addItem(to: viewMenu, title: "Zoom In", action: #selector(zoomIn), binding: MenuShortcuts.zoomInUnshifted)
        unshifted.isHidden = true
        unshifted.allowsKeyEquivalentWhenHidden = true
        addItem(to: viewMenu, title: "Zoom Out", action: #selector(zoomOut), binding: MenuShortcuts.zoomOut)
        self.viewMenu = viewMenu
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Services menu
        let servicesMenu = NSMenu(title: "Services")
        // Cmd+Ctrl rather than bare Cmd (#123). These took Cmd+S, Cmd+X and
        // Cmd+R — Save, Cut and Reload everywhere else on the platform — and the
        // main menu matches key equivalents before the WKWebView sees them, so
        // cutting a line of Python stopped the backend and saving a model
        // started services instead.
        //
        // They are deliberate, infrequent actions; a two-modifier chord suits
        // them. Stop Services keeps none at all: it is the destructive one, it
        // is never urgent, and a stray keystroke should not be able to reach it.
        addItem(to: servicesMenu, title: "Start Services",
                action: #selector(startServices), binding: MenuShortcuts.startServices)
        addItem(to: servicesMenu, title: "Stop Services", action: #selector(stopServices))
        addItem(to: servicesMenu, title: "Restart Services",
                action: #selector(restartServices), binding: MenuShortcuts.restartServices)
        let servicesMenuItem = NSMenuItem()
        servicesMenuItem.submenu = servicesMenu
        mainMenu.addItem(servicesMenuItem)

        // Development menu. The dynamic parts — Developer-mode entries and the
        // running backend port — are rebuilt on open (#43), but the fixed items
        // are added *now*: a key equivalent can only fire if its item exists, and
        // items created solely in `menuNeedsUpdate` don't exist until the user has
        // opened the menu at least once. That is why ⌘B never worked. (#75)
        devMenu = NSMenu(title: "Development")
        devMenu.delegate = self
        addFixedDevelopmentItems(to: devMenu)
        let devMenuItem = NSMenuItem()
        devMenuItem.submenu = devMenu
        mainMenu.addItem(devMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        addItem(to: windowMenu, title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), binding: MenuShortcuts.minimize)
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Help menu. Report a Problem works even when PsyNeuView won't start:
        // its screen is in the Logs window (#202, PsyNeuView-archive#1279). No
        // shortcut, so MenuShortcuts has nothing to declare for it.
        let helpMenu = NSMenu(title: "Help")
        addItem(to: helpMenu, title: "Report a Problem…", action: #selector(showReportProblem))
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
        // Ask the feed once, quietly, so a waiting update shows in the window
        // without waiting hours for Sparkle's next scheduled check (#6). No
        // window or alert: Sparkle's own prompt still comes on its schedule.
        if AppIdentity.current.updatesEnabled {
            sparkleUpdater.updater.checkForUpdateInformation()
        }
    }

    // MARK: - Development menu (dynamic)

    /// Rebuild the Development menu each time it opens, so it reflects the live
    /// Developer-mode toggle and the current backend port. In Developer mode it
    /// exposes the running URLs, API docs, and the on-disk repo — the
    /// "see what's happening on your machine" tools for a developer (#43).
    /// The items that are always present, added at menu-creation time so their
    /// key equivalents are registered from launch. (#75)
    ///
    /// "Switch Branch" only applies to a checkout, so it is hidden when PsyNeuView
    /// came bundled with the app — there is no branch to switch (#74).
    ///
    /// Updating the checkout is not here, deliberately. It was tried, on the
    /// grounds that both act on the checkout — but it belongs in the App menu
    /// next to the app update, so the two can be told apart (#167). It is a
    /// developer item there, shown only in developer mode (#214).
    private func addFixedDevelopmentItems(to menu: NSMenu) {
        if !usingBundledPsyNeuView {
            addItem(to: menu, title: "Switch Branch...", action: #selector(showBranchPicker), binding: MenuShortcuts.switchBranch)
        }
        addItem(to: menu, title: "View Logs", action: #selector(showLogWindow), binding: MenuShortcuts.viewLogs)
        menu.addItem(withTitle: "Setup Wizard...", action: #selector(showSetupWizard), keyEquivalent: "")
    }

    /// Fill in what each update item is at, just before the menu is drawn.
    ///
    /// Both values can change while the app runs — an installed update, a
    /// branch switch — so they are read here rather than at menu-creation time.
    private func refreshUpdateMenuTitles() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        appUpdateItem?.title = UpdateMenuTitles.appUpdate(
            installedVersion: version, updatesEnabled: AppIdentity.current.updatesEnabled)

        // The folder and the branch it is actually on, not the branch the app
        // remembers: the item names what a pull would touch (#214).
        let repoPath = preferences.repoPath
        let tracksGit = repoPath.map(Updater.tracksUpdatesWithGit(repoPath:)) ?? false
        codeUpdateItem?.title = UpdateMenuTitles.codeUpdate(
            path: repoPath?.path,
            branch: repoPath.flatMap(Updater.currentBranch(repoPath:)),
            tracksGit: tracksGit)
        refreshCodeUpdateVisibility()
    }

    /// Show the checkout item (and its "Developer" header) only in developer
    /// mode (#214). Called when the mode changes — from PsyNeuView's Settings
    /// through the `pnvSettings` bridge — and again whenever the App menu
    /// opens, so the menu never trusts a stale copy of the setting.
    private func refreshCodeUpdateVisibility() {
        let shown = UpdateMenuTitles.showsCodeUpdate(developerMode: preferences.developerMode)
        for item in codeUpdateDeveloperItems { item.isHidden = !shown }
    }

    /// Whether this install is running the PsyNeuView shipped inside the app.
    private var usingBundledPsyNeuView: Bool {
        !BundledPsyNeuView.offersBranchSwitching(
            useBundledApp: preferences.useBundledApp,
            hasBundledArchive: BundledPsyNeuView.archiveURL() != nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === viewMenu {
            refreshViewMenu(menu)
            return
        }
        if menu === appUpdateItem?.menu {
            refreshUpdateMenuTitles()
            return
        }
        guard menu === devMenu else { return }
        menu.removeAllItems()
        addFixedDevelopmentItems(to: menu)

        guard preferences.developerMode else { return }

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let running = appState.backendPort > 0
        let urlItem = menu.addItem(withTitle: running ? "Open App (localhost:\(appState.backendPort))" : "Open App (not running)",
                                   action: #selector(openBackendURL), keyEquivalent: "")
        urlItem.isEnabled = running
        let docsItem = menu.addItem(withTitle: "Open API Docs (/docs)", action: #selector(openAPIDocs), keyEquivalent: "")
        docsItem.isEnabled = running
        let copyItem = menu.addItem(withTitle: "Copy Backend URL", action: #selector(copyBackendURL), keyEquivalent: "")
        copyItem.isEnabled = running

        menu.addItem(.separator())
        let hasRepo = preferences.repoPath != nil
        let revealItem = menu.addItem(withTitle: "Reveal Repo in Finder", action: #selector(revealRepoInFinder), keyEquivalent: "")
        revealItem.isEnabled = hasRepo
        let editItem = menu.addItem(withTitle: "Open Repo in Editor", action: #selector(openRepoInEditor), keyEquivalent: "")
        editItem.isEnabled = hasRepo
        menu.addItem(withTitle: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Run Self-Check…", action: #selector(runSelfCheck), keyEquivalent: "")
    }

    private var backendURLString: String { "http://localhost:\(appState.backendPort)" }

    @objc func openBackendURL() {
        guard appState.backendPort > 0, let url = URL(string: backendURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openAPIDocs() {
        guard appState.backendPort > 0, let url = URL(string: backendURLString + "/docs") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyBackendURL() {
        guard appState.backendPort > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(backendURLString, forType: .string)
        logCollector.add("Copied backend URL: \(backendURLString)", source: .system)
    }

    @objc func revealRepoInFinder() {
        guard let repoPath = preferences.repoPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repoPath])
    }

    @objc func openRepoInEditor() {
        guard let repoPath = preferences.repoPath else { return }
        // Best-effort: VS Code if `code` is on PATH, else open the folder normally.
        Task {
            if let code = await Shell.which("code") {
                _ = try? await Shell.run(code, arguments: [repoPath.path])
            } else {
                await MainActor.run { _ = NSWorkspace.shared.open(repoPath) }
            }
        }
    }

    @objc func copyDiagnostics() {
        let diag = """
        PsyNeuView-MacApp diagnostics
        app:           \(AppIdentity.current.displayName) (\(AppIdentity.current.bundleIdentifier))
        app version:   \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        build commit:  \(VersionReport.buildCommit() ?? "(not stamped)")
        backend:       \(appState.backendPort > 0 ? backendURLString : "(not running)")
        repo path:     \(preferences.repoPath?.path ?? "(not set)")
        install:       \(InstallSwitch.describeRunning(preferences.repoPath))
        PsyNeuView br: \(preferences.branch)
        PsyNeuLink:    \(preferences.pnlSourceDescription)
        developer:     \(preferences.developerMode)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diag, forType: .string)
        logCollector.add("Copied diagnostics to clipboard", source: .system)
    }

    // MARK: - Self-Check

    /// One-stop health report: backend services, PsyNeuLink source, code-checkout
    /// freshness, and the full Sparkle auto-update chain (feed → newest version →
    /// download reachable → signing key). The update section mirrors the manual
    /// end-to-end test and, in particular, catches the case where the update DMG
    /// isn't anonymously downloadable (which silently breaks auto-update — see #52).
    @objc func runSelfCheck() {
        logCollector.add("Running self-check…", source: .system)

        // Snapshot main-actor state before hopping onto async work.
        let port = appState.backendPort
        let repoPath = preferences.repoPath
        let branch = preferences.branch
        let pnlDesc = preferences.pnlSourceDescription
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let feedString = info?["SUFeedURL"] as? String ?? ""
        let pubKey = info?["SUPublicEDKey"] as? String ?? ""

        Task { @MainActor in
            var lines: [String] = []
            func row(_ ok: Bool?, _ label: String, _ detail: String) {
                let sym = ok == nil ? "•" : (ok! ? "✓" : "✗")
                lines.append("\(sym) \(label): \(detail)")
            }

            row(true, "App version", appVersion)

            // Backend / services
            if port > 0, let url = URL(string: "http://localhost:\(port)/api/settings/info") {
                let ok = await Self.httpReachable(url)
                row(ok, "Backend services", ok ? "healthy (localhost:\(port))" : "not responding (localhost:\(port))")
            } else {
                row(false, "Backend services", "not running")
            }

            row(true, "PsyNeuLink source", pnlDesc)

            // Code checkout freshness
            if let repo = repoPath {
                row(true, "Code checkout", "\(repo.path) · branch \(branch)")
                if Updater.tracksUpdatesWithGit(repoPath: repo) {
                    let updatesAvailable = await updater.checkForUpdates(repoPath: repo)
                    row(!updatesAvailable, "Code up to date",
                        updatesAvailable
                            ? "updates available — run “Update PsyNeuView checkout…” in the App menu (developer mode)"
                            : "up to date with origin")
                } else {
                    // "up to date with origin" would be a lie: there is no origin. (#87)
                    let bundledVersion = BundledPsyNeuView.installedVersion(at: repo)
                    row(true, "PsyNeuView code",
                        bundledVersion.map { "\($0), bundled with the app" }
                            ?? "bundled with the app — arrives with app updates")
                }
            } else {
                row(false, "Code checkout", "repo not configured — run Setup Wizard")
            }

            // Auto-update chain (mirrors the manual end-to-end test)
            var latest: String?
            var enclosure: URL?
            if !feedString.isEmpty, let feed = URL(string: feedString) {
                if let parsed = await Self.fetchAppcastLatest(feed) {
                    latest = parsed.version; enclosure = parsed.enclosure
                    row(true, "Update feed", "reachable · latest \(parsed.version)")
                } else {
                    row(false, "Update feed", "unreachable or unparseable (\(feedString))")
                }
            } else {
                row(false, "Update feed", "no SUFeedURL configured")
            }

            if let latest = latest {
                let newer = latest != appVersion && SemanticVersion.isAtLeast(latest, minimum: appVersion)
                row(nil, "App update", newer ? "\(latest) available (installed \(appVersion))" : "up to date (\(appVersion))")
            }

            if let enclosure = enclosure {
                let ok = await Self.httpReachable(enclosure, method: "HEAD")
                row(ok, "Update download",
                    ok ? "reachable (\(enclosure.lastPathComponent))"
                       : "NOT reachable — auto-update would fail\n    \(enclosure.absoluteString)")
            }

            row(!pubKey.isEmpty, "Update signing key", pubKey.isEmpty ? "MISSING (SUPublicEDKey)" : "present")

            let report = lines.joined(separator: "\n")
            logCollector.add("Self-check results:\n\(report)", source: .system)
            Self.presentSelfCheck(report)
        }
    }

    /// GET/HEAD a URL and report a 2xx, following redirects as Sparkle does.
    private static func httpReachable(_ url: URL, method: String = "GET") async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Fetch the appcast and pull the newest item's version + enclosure URL.
    /// Lightweight string scan — the appcast lists the newest <item> first.
    private static func fetchAppcastLatest(_ feed: URL) async -> (version: String, enclosure: URL)? {
        var request = URLRequest(url: feed)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8),
              let parsed = AppcastParser.latest(fromXML: xml),
              let url = URL(string: parsed.enclosureURL) else { return nil }
        return (parsed.version, url)
    }

    @MainActor
    private static func presentSelfCheck(_ report: String) {
        // Menu-bar (accessory) apps must activate before showing a modal, or the
        // alert can be created without ever coming to the front.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "PsyNeuView Self-Check"
        alert.informativeText = report
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Report")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    // MARK: - State Updates

    private func onStateChanged() {
        updateMenubarIcon()
        statusMenu.update()
    }

    private func updateMenubarIcon() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        switch appState.overallStatus {
        case .running:  symbolName = "brain.fill"
        case .starting, .stopping: symbolName = "brain"
        case .error:    symbolName = "brain"
        case .stopped:  symbolName = "brain"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PsyNeuView") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        }

        // Tint based on status
        switch appState.overallStatus {
        case .running:
            button.contentTintColor = .systemGreen
        case .starting, .stopping:
            button.contentTintColor = .systemYellow
        case .error:
            button.contentTintColor = .systemRed
        case .stopped:
            button.contentTintColor = nil
        }
    }

    // MARK: - Menu Actions

    @objc func showBranchPicker() {
        guard let repoPath = preferences.repoPath else {
            logCollector.add("No repo path configured", source: .system)
            return
        }

        Task {
            logCollector.add("Fetching available branches...", source: .system)
            let branches = await updater.listBranches(repoPath: repoPath)

            guard !branches.isEmpty else {
                logCollector.add("No branches found", source: .system)
                return
            }

            // Gate the list: casual users only see the tested branches
            // (devel/main); Developer mode surfaces everything (#34).
            let visibleBranches = Preferences.visibleBranches(
                branches, developerMode: preferences.developerMode, current: preferences.branch)

            // Show as an alert with a popup button
            let alert = NSAlert()
            alert.messageText = "Switch Branch"
            let devHint = preferences.developerMode
                ? ""
                : "\n\nOnly tested branches are shown. Turn on Developer mode in Settings to switch to feature/unstable branches."
            alert.informativeText = "Current branch: \(preferences.branch)\n\nSelect a branch to switch to. The app will pull the latest code, rebuild, and restart.\(devHint)"
            alert.alertStyle = .informational

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
            for branch in visibleBranches {
                popup.addItem(withTitle: branch)
            }
            popup.selectItem(withTitle: preferences.branch)
            alert.accessoryView = popup

            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn,
                  let selectedBranch = popup.selectedItem?.title,
                  selectedBranch != preferences.branch else { return }

            // Stop services, switch branch, rebuild, restart
            showLogWindow()
            processManager.stopAll()
            try? await Task.sleep(for: .seconds(2))

            logCollector.add("Switching to branch: \(selectedBranch)", source: .system)
            let success = await updater.switchBranch(to: selectedBranch, repoPath: repoPath)

            if success {
                logCollector.add("Restarting on \(selectedBranch) branch...", source: .system)
                for window in appWindows { window.close() }
                appWindows.removeAll()
                startServices()
            } else {
                logCollector.add("Branch switch failed — check logs", source: .system, isError: true)
            }
        }
    }

    /// Grey out "Update PsyNeuView Code…" when there is no checkout to update.
    /// Re-evaluated whenever the menu opens, so it copes with the repo path being
    /// configured after launch. (#87)
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates) else { return true }
        guard let repoPath = preferences.repoPath else { return false }
        return Updater.tracksUpdatesWithGit(repoPath: repoPath)
    }

    @objc func checkForUpdates() {
        guard let repoPath = preferences.repoPath else {
            logCollector.add("No repo path configured", source: .system)
            return
        }
        guard Updater.tracksUpdatesWithGit(repoPath: repoPath) else {
            showLogWindow()
            logCollector.add(
                "PsyNeuView is bundled with this app, so there is no separate code update. "
                + "Use “Check for App Updates…” instead.",
                source: .system)
            return
        }

        showLogWindow()
        Task {
            // Ask before stopping anything: a refused pull (uncommitted
            // changes, a diverged branch) must leave the running app alone and
            // say why in the log (#214).
            logCollector.add(
                "Checking \(InstallSwitch.abbreviated(repoPath.path)) against origin...",
                source: .system)
            switch await updater.pullReadiness(repoPath: repoPath) {
            case .refuse(let why):
                logCollector.add(why, source: .system, isError: true)
                return
            case .nothingToPull(let why):
                logCollector.add(why, source: .system)
                return
            case .pull(let branch):
                logCollector.add("Updates available on \(branch).", source: .system)
            }

            // Stop services before updating
            processManager.stopAll()
            try? await Task.sleep(for: .seconds(2))

            logCollector.add("Checking for updates...", source: .system)
            let success = await updater.update(repoPath: repoPath)
            if success {
                logCollector.add("Restarting with updated code...", source: .system)
                // Close app windows so they reload with new code
                for window in appWindows { window.close() }
                appWindows.removeAll()
                startServices()
            }
        }
    }

    @objc func startServices() {
        servicesStartedAt = Date()
        guard let repoPath = preferences.repoPath else {
            selectRepoPath()
            return
        }

        // The app's record of the PsyNeuLink source follows what is actually
        // installed (#9), so About, Problem Reports and any later rebuild agree
        // with the page.
        reconcilePsyNeuLinkRecord(repoPath: repoPath)

        // Verify the tree is still there and runnable. Accepts a bundled tree as
        // well as a clone — the bundled one has no Makefile. (#89)
        guard BundledPsyNeuView.isRunnableTree(at: repoPath) else {
            let message = "PsyNeuView isn't where it was installed "
                + "(\(repoPath.path)). Run the Setup Wizard to reinstall it."
            logCollector.add(message, source: .system, isError: true)
            // Say it where the user is looking, not only in the log. (#96)
            showStartingFailure(message)
            return
        }

        // Anything the user saved into the tree's models/ is in storage we are
        // entitled to delete. Move it somewhere durable before going further.
        // (PsyNeuView-archive#1089)
        let rescued = BundledPsyNeuView.rescueUserModels(fromTree: repoPath)
        if !rescued.isEmpty {
            logCollector.add(
                "Moved \(rescued.count) saved model(s) to "
                + "\(BundledPsyNeuView.userModelsDirectory().path), where app updates "
                + "can't remove them: \(rescued.joined(separator: ", "))",
                source: .system)
        }

        // The tree is fine but the environment may not be. Rebuild it rather than
        // logging "run the Setup Wizard" and stopping — the app knows how, and a
        // 0.5.2 user was left with a spinner and a log line nobody opens. (#106)
        guard BundledPsyNeuView.hasUsableEnvironment(at: repoPath) else {
            repairEnvironment(at: repoPath)
            return
        }

        // The start continues the checklist a repair or an update began, or
        // is a checklist of its own (#196).
        if !(startupProgress?.isPending(.startServer) ?? false) {
            beginProgress(ProgressPlan.steps(for: .start))
        }
        startupProgress?.begin(.startServer)
        // The line above the checklist names the server now, whatever the
        // refresh or repair before it said (#232).
        if startingWindow != nil { updateStartingStatus(StartupDecision.startingMessage) }

        Task { @MainActor in
            await processManager.startAll(repoPath: repoPath)
        }
    }

    /// Steps, times and time left for what the starting window is waiting on
    /// (#196). Nil when nothing is being installed or started.
    private var startupProgress: InstallProgress? {
        didSet { if let startupProgress { reportProgress = startupProgress } }
    }
    /// What the starting window last said, so it can be redrawn with a new
    /// checklist without changing the words.
    private var startingStatus = StartupDecision.startingMessage

    /// The starting window's content. Its size is the window's, not the
    /// view's: the checklist grows and shrinks as notices come and go, and
    /// letting it resize the window made it run off the screen (#196).
    private func startingHost(_ view: StartingView) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        return host
    }

    /// Start a new checklist and show it in the starting window, if open.
    private func beginProgress(_ steps: [ProgressStep]) {
        startupProgress = InstallProgress.recorded(steps)
        if startingWindow != nil { updateStartingStatus(startingStatus) }
    }

    @objc func stopServices() {
        processManager.stopAll()
    }

    @objc func restartServices() {
        guard let repoPath = preferences.repoPath else { return }
        // Close the current app window(s) first — they point at the old backend
        // (and possibly an old port), so leaving them open strands a stale window
        // next to the fresh one. A new window reopens via `onServiceReady` once
        // services are back up. Closing while services are still running keeps
        // `appState.canStop` true, so windowWillClose won't quit the app.
        for window in appWindows { window.close() }
        appWindows.removeAll()
        Task { @MainActor in
            await processManager.restartAll(repoPath: repoPath)
        }
    }

    /// The "starting" window, if one is open. Replaced by the real app window
    /// once the backend is ready. (#96)
    private var startingWindow: NSWindow?

    /// About shows all three versions, because they move independently and a bug
    /// report needs all three: the app, the PsyNeuView it bundles, and the
    /// PsyNeuLink it installed — which is *not* bundled, and whose source is
    /// configurable. (#57, jonhanke-nam/PsyNeuView-archive#1073)
    /// When services were last asked to start, for the elapsed time the
    /// startup decision needs (#104).
    private var servicesStartedAt: Date?

    private let aboutWindowController = AboutWindowController()

    /// "PsyNeuView", or "PsyNeuView Test 0.5.19" for the test app (#209).
    static var windowTitle: String {
        AppIdentity.current.windowTitle(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    @objc func showAbout() {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = bundle.infoDictionary?["CFBundleVersion"] as? String

        var psyNeuViewVersion: String?
        var checkoutPath: String?
        var checkoutBranch: String?
        var psyNeuLinkVersion: String?
        if let repo = preferences.repoPath {
            // Which kind of install, the same way Settings decides it (#195).
            switch InstallSwitch.kind(of: InstallSwitch.facts(at: repo)) {
            case .bundled(let version):
                psyNeuViewVersion = version
                if version == nil { checkoutPath = InstallSwitch.abbreviated(repo.path) }
            case .checkout:
                checkoutPath = InstallSwitch.abbreviated(repo.path)
                checkoutBranch = InstallSwitch.currentBranch(at: repo)
            }
            psyNeuLinkVersion = VersionReport.installedVersion(
                of: "psyneulink",
                inVenv: repo.appendingPathComponent("backend/.venv"))
        }

        let lines = VersionReport.aboutLines(
            appVersion: appVersion,
            appBuild: appBuild,
            psyNeuViewVersion: psyNeuViewVersion,
            checkoutPath: checkoutPath,
            checkoutBranch: checkoutBranch,
            psyNeuLinkVersion: psyNeuLinkVersion,
            psyNeuLinkSource: livePsyNeuLinkDescription(),
            availableSources: VersionReport.availablePsyNeuLinkSources(),
            identity: AppIdentity.current,
            buildCommit: VersionReport.buildCommit(),
            bundlePath: InstallSwitch.abbreviated(bundle.bundlePath),
            dataFolder: InstallSwitch.abbreviated(BundledPsyNeuView.supportDirectory().path)
        )

        // Our own window rather than orderFrontStandardAboutPanel, so the text
        // can be resized and pinched. The standard panel is fixed-size and
        // ignores magnification (#128).
        //
        // This supersedes the font bump from #129: that enlarged the text in
        // the standard panel, which was the right small fix at the time. This
        // window sets its own sizes and they scale with the zoom.
        aboutWindowController.show(lines: lines)
    }

    /// Open a window immediately, before the backend is up, so a finished setup
    /// hands the user the app rather than a debug log.
    func showStartingWindow(status: String = "Starting the PsyNeuView server…") {
        startingStatus = status
        if let existing = startingWindow {
            // Refresh the message: the window may already be open showing
            // "Starting the PsyNeuView server…" when we discover we are actually
            // rebuilding the environment, which takes minutes rather than
            // seconds. (#106)
            existing.contentView = startingHost(StartingView(
                status: status,
                failure: nil,
                onShowLogs: { [weak self] in self?.showLogWindow() },
                onRetry: { [weak self] in self?.retryStart() },
                progress: startupProgress
            ))
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = StartingView(
            status: status,
            failure: nil,
            onShowLogs: { [weak self] in self?.showLogWindow() },
            onRetry: { [weak self] in self?.retryStart() },
            progress: startupProgress
        )
        // Native on purpose (PsyNeuView-archive#1279): shown before the server, and so React, is up.
        let window = NSWindow(
            // Tall enough for the eight-step checklist of an update followed
            // by a start, with a notice or two under it (#196, #232).
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = startingHost(view)
        window.title = Self.windowTitle
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startingWindow = window
    }

    /// Replace the starting window's contents when startup fails, so "still
    /// working" and "broken" stop looking identical.

    /// Seconds since services were last asked to start.
    private var elapsedSinceStart: TimeInterval {
        guard let startedAt = servicesStartedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Put on screen whatever the decision says belongs there (#104).
    ///
    /// The window mechanics stay here; what to show does not. Previously a
    /// failure always offered "Try Again", including when the process had
    /// exited and retrying could not help — which is how one install logged
    /// "Cannot start" four times (#101).
    private func applyStartupScreen(elapsed: TimeInterval, backendRunning: Bool) {
        let screen = StartupDecision.screen(for: .init(
            setupCompleted: setupCompleted,
            backendHealthy: appState.backendStatus == .running,
            backendRunning: backendRunning,
            elapsed: elapsed,
            ceiling: Constants.healthTimeout,
            reassureAfter: Constants.healthSlowAfter))

        switch screen {
        case .app, .setupWizard:
            // Reaching either from here means the start finished or was never
            // needed; the existing paths already own those windows.
            break
        case .starting(let message):
            updateStartingStatus(message)
        case .failed(let reason, let retryable):
            showStartingFailure(reason, retryable: retryable)
        }
    }

    func showStartingFailure(_ message: String, retryable: Bool = true) {
        startupProgress?.failCurrent(reason: message)
        lastStartupOutcome = "didn't start: \(message)"
        guard let window = startingWindow else { return }
        window.contentView = startingHost(StartingView(
            status: "",
            failure: message,
            onShowLogs: { [weak self] in self?.showLogWindow() },
            onRetry: retryable ? { [weak self] in self?.retryStart() } : nil,
            progress: startupProgress,
            onReport: { [weak self] in self?.showReportProblem() }
        ))
    }

    /// Replace the starting window's status text in place. (#101)
    func updateStartingStatus(_ status: String) {
        startingStatus = status
        guard let window = startingWindow else { return }
        window.contentView = startingHost(StartingView(
            status: status,
            failure: nil,
            onShowLogs: { [weak self] in self?.showLogWindow() },
            onRetry: { [weak self] in self?.retryStart() },
            progress: startupProgress
        ))
    }

    /// Rebuild a missing Python environment, then start.
    ///
    /// Says what it is doing and roughly how long it takes: this is the same
    /// multi-minute dependency install setup performs, and silence during it is
    /// what made the original failure look like a hang. (#106)
    func repairEnvironment(at repoPath: URL) {
        // Continues an update's checklist, which already lists these steps;
        // otherwise a checklist of its own (#196).
        if !(startupProgress?.isPending(.installPackages) ?? false) {
            beginProgress(ProgressPlan.steps(for: .repair))
        }
        showStartingWindow(status: "Finishing setup — installing Python packages. "
                                 + "This takes a few minutes.")
        logCollector.add(
            "Python environment missing at \(repoPath.path)/backend/.venv — rebuilding it.",
            source: .system)

        let installer = Installer()
        installer.onOutput = { [weak self] text in
            self?.logCollector.add(text, source: .system)
        }
        installer.onStepChange = { [weak self] step, status in
            self?.startupProgress?.apply(step, status)
        }
        installer.onDetail = { [weak self] step, detail in
            self?.startupProgress?.note(detail, under: ProgressStep(step))
        }

        Task { @MainActor in
            let repaired = await installer.repairEnvironment(
                repoPath: repoPath, pnlPipArgs: pnlPipArgsKeepingLiveSource(leaving: repoPath))
            if repaired {
                logCollector.add("Environment rebuilt — starting PsyNeuView.", source: .system)
                startServices()
            } else {
                showStartingFailure(
                    "Couldn't install the Python packages PsyNeuView needs. "
                    + "Check the logs, then try again.")
            }
        }
    }

    /// Retry, but only when there is something to retry.
    ///
    /// The button used to call startServices() unconditionally, and while the
    /// backend was still starting `startAll` refused with "Cannot start: server
    /// is not in stopped state" — so the one recovery offered did nothing and
    /// said something confusing. A 0.5.3 user clicked it four times. (#101)
    func retryStart() {
        guard appState.canStart else {
            logCollector.add(
                "Still starting — waiting for the server rather than restarting it.",
                source: .system)
            return
        }
        startupProgress = nil
        showStartingWindow()
        startServices()
    }

    private func closeStartingWindow() {
        startingWindow?.close()
        startingWindow = nil
    }

    /// Suppresses repeats of the still-starting notice, which would otherwise be
    /// logged on every attempt while a long install runs.
    private var announcedStillStarting = false

    @objc func showAppWindow() {
        guard appState.backendPort > 0 else {
            // Not an error -- the backend simply has not finished starting. Say
            // that plainly: this line is the last thing in the log during a long
            // install, and phrased as an internal condition it reads as a hang
            // rather than as progress (#146).
            if !announcedStillStarting {
                announcedStillStarting = true
                logCollector.add(
                    "Still starting up — the window opens once the backend is ready. "
                        + "First run and post-update starts can take a few minutes.",
                    source: .system
                )
            }
            return
        }
        announcedStillStarting = false

        let urlString = Constants.frontendURL(port: appState.backendPort)
        guard let url = URL(string: urlString) else { return }

        // An update must show its own page, not the last version's from the
        // web cache (#1): clear the cache first when the app or PsyNeuView changed.
        WebCache.clearIfNeeded(
            repoPath: appState.repoPath,
            log: { [weak self] line in self?.logCollector.add(line, source: .system) },
            then: { [weak self] in self?.openAppWindow(url: url) })
    }

    private func openAppWindow(url: URL) {
        let settingsWanted = openSettingsWhenWindowOpens
        let webView = AppWindowView(
            url: url, settingsHost: settingsHost, openSettingsOnLoad: settingsWanted,
            pagePreferences: pagePreferences)
        openSettingsWhenWindowOpens = false
        let hostingView = NSHostingView(rootView: webView)

        // The app window: it hosts PsyNeuView's React UI, where all other UI lives (PsyNeuView-archive#1279).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = Self.windowTitle
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        appWindows.append(window)
        closeStartingWindow()

        // Once a launch, and whenever ⌘, was what opened the window (#205).
        if !tooOldOfferShown || settingsWanted {
            tooOldOfferShown = offerSwitchIfTooOld(askedForSettings: settingsWanted, window: window)
                || tooOldOfferShown
        }
    }

    // MARK: - A PsyNeuView too old for the app's Settings (#205)

    /// Whether this launch has shown the too-old offer.
    private var tooOldOfferShown = false

    /// When the PsyNeuView in use is older than the app's Settings need, say
    /// so and offer to switch to the included one. Returns whether it did.
    ///
    /// A sheet, not a window of our own (PsyNeuView-archive#1279): the page is too old
    /// to show anything for us, so the app has to.
    ///
    /// - Parameter askedForSettings: ⌘, — shown even after "Not Now", which
    ///   only quiets the offer at launch.
    @discardableResult
    private func offerSwitchIfTooOld(askedForSettings: Bool, window: NSWindow?) -> Bool {
        guard let repo = preferences.repoPath,
              case .tooOld(let version) = SettingsSupport.verdict(
                  version: SettingsSupport.version(at: repo))
        else { return false }
        let key = SettingsSupport.dismissalKey(path: repo.path, version: version)
        if !askedForSettings && preferences.tooOldOfferDismissed == key { return false }
        if let window, window.attachedSheet != nil { return true }

        let offer = SettingsSupport.offer(
            version: version,
            running: InstallSwitch.describeRunning(repo),
            isCheckout: InstallSwitch.kind(of: InstallSwitch.facts(at: repo)) == .checkout,
            archiveVersion: BundledPsyNeuView.archiveURL()
                .flatMap { BundledPsyNeuView.version(fromArchiveName: $0.lastPathComponent) })
        logCollector.add(
            "PsyNeuView \(version) is older than \(SettingsSupport.minimumVersion), which the "
                + "app's Settings need. Offering "
                + (offer.switchToVersion.map { "to switch to the included \($0)." } ?? "Report a Problem."),
            source: .system)

        let alert = NSAlert()
        alert.messageText = offer.title
        alert.informativeText = offer.message
        alert.alertStyle = .warning
        if let included = offer.switchToVersion {
            alert.addButton(withTitle: "Switch to PsyNeuView \(included)")
        }
        alert.addButton(withTitle: "Report a Problem…")
        alert.addButton(withTitle: "Not Now")
        let hasSwitch = offer.switchToVersion != nil
        let respond = { [weak self] (response: NSApplication.ModalResponse) in
            guard let self else { return }
            let button = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            switch (hasSwitch, button) {
            case (true, 0):
                self.logCollector.add("Too-old offer: switching to the included PsyNeuView.", source: .system)
                self.switchInstall(self.settingsHost.decide(.bundled))
            case (true, 1), (false, 0):
                self.showReportProblem()
            default:
                self.logCollector.add("Too-old offer: not now.", source: .system)
                self.preferences.tooOldOfferDismissed = key
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
        return true
    }


    // MARK: - Report a Problem (#202)

    /// Help ▸ Report a Problem…, the Logs window's button and the failed
    /// starting window's button all come here: the report screen, in the Logs
    /// window, which works whether or not PsyNeuView started.
    @objc func showReportProblem() {
        problemReport.open()
        showLogWindow()
    }

    /// The #186 move's outcome, dated, kept for the report.
    private func recordMoveOutcome(_ what: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        preferences.lastMoveOutcome = "\(f.string(from: Date())): \(what)"
    }

    private func configureProblemReport() {
        let report = problemReport
        report.gatherFacts = { [weak self] in
            self?.reportFacts() ?? ProblemReport.Facts(
                appVersion: "?", install: "?", psyNeuLinkSource: "?", developerMode: false,
                server: "?", steps: [], macOSVersion: "?", macModel: "?")
        }
        // The whole launch, from its file (#208); the window's own list
        // when the file couldn't be written.
        report.gatherLogs = { [weak self] in
            guard let self else { return [] }
            let fromFile = self.launchLog.currentLines()
            if !fromFile.isEmpty { return fromFile }
            return self.appState.logs.map {
                "[\($0.formattedTimestamp)] [\($0.source.rawValue)]\($0.isError ? " [error]" : "") \($0.text)"
            }
        }
        report.gatherPreviousLogs = { [weak self] in
            guard let self else { return nil }
            let age = Date().timeIntervalSince(self.launchDate)
            guard ProblemReport.attachPreviousLaunch(
                launchAge: age, previousAvailable: self.launchLog.previousFileURL != nil) else { return nil }
            return self.launchLog.previousLines()
        }
        report.gatherSettings = { [weak self] in self?.settingsSnapshot() }
        report.gatherPageDiagnostics = { [weak self] done in
            guard let self, let webView = self.frontmostAppWebView(), webView.url != nil else {
                return done(PageDiagnostics.noPage())
            }
            self.askPageForDiagnostics(webView, done: done)
        }
        report.captureAppWindow = { [weak self] done in
            guard let webView = self?.frontmostAppWebView() else { return done(nil) }
            webView.takeSnapshot(with: nil) { image, _ in
                Task { @MainActor in done(image) }
            }
        }
        report.sendWith = { [weak self] in self?.preferences.reportSendWith ?? "ask" }
        report.sendTo = { [weak self] in self?.preferences.reportSendTo ?? "" }
        report.developerMode = { [weak self] in self?.preferences.developerMode ?? false }
    }

    /// Every app setting, for the report (#208).
    private func settingsSnapshot() -> SettingsSnapshot.Values {
        // A report states the PsyNeuLink actually installed, not a stale record (#9).
        reconcilePsyNeuLinkRecord(repoPath: appState.repoPath ?? preferences.repoPath)
        let sparkle = sparkleUpdater.updater
        return preferences.snapshotValues(
            lastBackendPort: PortChecker.rememberedPort(),
            pagePreferenceKeys: pagePreferences.keys,
            updateCheck: SettingsSnapshot.UpdateCheck(
                lastCheck: sparkle.lastUpdateCheckDate,
                automatic: sparkle.automaticallyChecksForUpdates,
                interval: sparkle.updateCheckInterval))
    }

    /// `window.__pnvDiagnostics()` in the page (#208, PsyNeuView-archive#1287), with
    /// `PageDiagnostics.timeout`. `done` is called exactly once, on the main
    /// actor; the report never waits on the page for longer than that.
    private func askPageForDiagnostics(
        _ webView: WKWebView, done: @escaping @MainActor (PageDiagnostics.Outcome) -> Void
    ) {
        var answered = false
        let finish: @MainActor (PageDiagnostics.Outcome) -> Void = { outcome in
            guard !answered else { return }
            answered = true
            done(outcome)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PageDiagnostics.timeout))
            finish(PageDiagnostics.timedOut())
        }
        webView.callAsyncJavaScript(PageDiagnostics.script, arguments: [:], in: nil, in: .page) { result in
            let outcome: PageDiagnostics.Outcome
            switch result {
            case .success(let value): outcome = PageDiagnostics.outcome(result: value, error: nil)
            case .failure(let error): outcome = PageDiagnostics.outcome(result: nil, error: error)
            }
            Task { @MainActor in finish(outcome) }
        }
    }

    /// The web view of the app window in front, or of any app window.
    private func frontmostAppWebView() -> WKWebView? {
        let ordered = NSApp.orderedWindows.filter { w in appWindows.contains { $0 === w } }
        for window in ordered + appWindows {
            if let view = window.contentView.flatMap(Self.findWebView) { return view }
        }
        return nil
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let web = findWebView(in: sub) { return web }
        }
        return nil
    }

    private func reportFacts() -> ProblemReport.Facts {
        let info = Bundle.main.infoDictionary
        var psyNeuViewVersion: String?
        var psyNeuLinkVersion: String?
        if let repo = preferences.repoPath {
            switch InstallSwitch.kind(of: InstallSwitch.facts(at: repo)) {
            case .bundled(let version): psyNeuViewVersion = version
            case .checkout: psyNeuViewVersion = SettingsSupport.version(at: repo)
            }
            psyNeuLinkVersion = VersionReport.installedVersion(
                of: "psyneulink", inVenv: repo.appendingPathComponent("backend/.venv"))
        }
        var server = appState.backendStatus.displayName.lowercased()
        if appState.backendPort > 0 { server += " on port \(appState.backendPort)" }
        return ProblemReport.Facts(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String,
            psyNeuViewVersion: psyNeuViewVersion,
            install: InstallSwitch.describeRunning(preferences.repoPath),
            psyNeuLinkSource: livePsyNeuLinkDescription(),
            psyNeuLinkVersion: psyNeuLinkVersion,
            developerMode: preferences.developerMode,
            server: server,
            startupOutcome: lastStartupOutcome,
            moveOutcome: preferences.lastMoveOutcome.isEmpty ? nil : preferences.lastMoveOutcome,
            settingsSupport: preferences.repoPath.map {
                SettingsSupport.reportLine(SettingsSupport.verdict(version: SettingsSupport.version(at: $0)))
            },
            steps: reportProgress?.reportSteps() ?? [],
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            macModel: Self.macModel(),
            pagePreferenceKeys: pagePreferences.keys)
    }

    /// "Mac15,6": the model identifier, as System Information shows it.
    private static func macModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    @objc func showLogWindow() {
        if let window = logWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let logView = LogWindowView(
            appState: appState, report: problemReport,
            onReportProblem: { [weak self] in self?.showReportProblem() })
        let hostingView = NSHostingView(rootView: logView)

        // Native on purpose (PsyNeuView-archive#1279): must work when the server can't start, to show why.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "PsyNeuView — Logs"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        // Show in dock when window is open
        NSApp.activate(ignoringOtherApps: true)

        logWindow = window
    }

    @objc func selectRepoPath() {
        let panel = NSOpenPanel()
        panel.title = "Select PsyNeuView Directory"
        panel.message = "Choose the root directory of your PsyNeuView checkout"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        // Start in the parent directory if we have a current path
        if let current = preferences.repoPath {
            panel.directoryURL = current.deletingLastPathComponent()
        }

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            // Validate: check for Makefile and backend/ directory
            let makefile = url.appendingPathComponent("Makefile")
            let backend = url.appendingPathComponent("backend")
            guard FileManager.default.fileExists(atPath: makefile.path),
                  FileManager.default.fileExists(atPath: backend.path) else {
                let alert = NSAlert()
                alert.messageText = "Invalid Directory"
                alert.informativeText = "The selected directory does not appear to be a PsyNeuView checkout. It should contain a Makefile and a backend/ directory."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }

            self.preferences.repoPath = url
            self.appState.repoPath = url
            self.logCollector.add("Repo path set to: \(url.path)", source: .system)
        }
    }

    /// ⌘, pressed before any app window could open; Settings opens in the
    /// first one (#200).
    private var openSettingsWhenWindowOpens = false

    /// Settings… ⌘, opens PsyNeuView's Settings — the same one as the gear
    /// icon — in the app window (#200). There is no native Settings window:
    /// two Settings with overlapping controls had already come to disagree.
    ///
    /// With an app window open, its page is asked to open Settings (the page
    /// holds the request if it's still loading). With none, one opens and
    /// Settings with it. Before the server is up, the request waits for the
    /// first window.
    @objc func showSettings() {
        let window = appWindows.first(where: { $0 === NSApp.keyWindow }) ?? appWindows.last
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // A page too old to have the app's Settings would open nothing (#205).
            if offerSwitchIfTooOld(askedForSettings: true, window: window) { return }
            NotificationCenter.default.post(name: SettingsBridge.openRequested, object: window)
            return
        }
        guard appState.backendPort > 0 else {
            openSettingsWhenWindowOpens = true
            logCollector.add(
                "Settings opens in the PsyNeuView window once it has started.", source: .system)
            startingWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openSettingsWhenWindowOpens = true
        showAppWindow()
    }

    /// The wizard's install, run with its defaults and no window (#174). Ends
    /// the way the wizard's completion does: record the install, then start.
    @MainActor
    private func runUnattendedSetup() async {
        let installer = Installer()
        installer.onOutput = { [weak self] text in
            self?.logCollector.add(text, source: .system)
        }
        installer.onStepChange = { [weak self] step, status in
            self?.startupProgress?.apply(step, status)
        }
        installer.onDetail = { [weak self] step, detail in
            self?.startupProgress?.note(detail, under: ProgressStep(step))
        }
        let ok = await installer.installAll(
            repoPath: BundledPsyNeuView.supportDirectory(),
            needsClone: false,
            pnlPipArgs: UnattendedSetup.defaultPipArgs,
            useBundled: true
        )
        guard ok, let installed = installer.resolvedRepoPath else {
            logCollector.add("Unattended setup failed; see the lines above.", source: .system)
            showStartingWindow(status: "Setup failed. Show Logs has the details.")
            return
        }
        preferences.repoPath = installed
        setupCompleted = true
        appState.repoPath = installed
        startServices()
    }

    /// Start a bundled install, first moving it to the PsyNeuView this app
    /// carries if the folder in use holds a different one (#186).
    ///
    /// App updates used to bring a new PsyNeuView that was never used, because
    /// launch always started the folder saved at first setup. Now the first
    /// launch after an update unpacks the new version, builds its environment,
    /// carries saved models across and switches to it, with nothing for the
    /// user to do.
    ///
    /// A move that fails must not leave anyone without a working app, so any
    /// failure starts the folder already in use, and the next launch tries
    /// again. The old folder is kept.
    @MainActor
    func startBundled(from current: URL) async {
        let archiveVersion = BundledPsyNeuView.archiveURL()
            .flatMap { BundledPsyNeuView.version(fromArchiveName: $0.lastPathComponent) }
        let treeVersion = BundledPsyNeuView.installedVersion(at: current)
        // A checkout without .git (a downloaded zip, say) still has a Makefile,
        // and is the user's own: never move it to the included version (#195).
        let isCheckout = InstallSwitch.kind(of: InstallSwitch.facts(at: current)) == .checkout
        let decision = BundledUpgrade.decide(
            isGitCheckout: isCheckout, treeVersion: treeVersion, archiveVersion: archiveVersion)
        guard case let .move(version) = decision else {
            startServices()
            return
        }

        logCollector.add(
            "This app carries PsyNeuView \(version); the install in use is "
                + "\(treeVersion ?? "an unstamped one") at \(current.path). Moving to \(version).",
            source: .system)
        beginProgress(ProgressPlan.steps(for: .update))
        showStartingWindow(status: "Updating PsyNeuView to \(version)… "
                                 + "This takes a few minutes, once.")

        func keepCurrent(_ reason: String) {
            recordMoveOutcome(
                "couldn't move to PsyNeuView \(version) because \(reason); "
                + "kept \(treeVersion ?? "the unstamped install") at \(current.path)")
            logCollector.add(
                "Couldn't move to PsyNeuView \(version) (\(reason)). Starting the one "
                    + "already installed; the next launch will try again.",
                source: .system, isError: true)
            startupProgress = nil
            showStartingWindow()
            startServices()
        }

        let newTree: URL
        switch await prepareIncludedPsyNeuView() {
        case .failure(let reason):
            keepCurrent(reason.message)
            return
        case .success(let tree):
            newTree = tree
        }

        // Models saved inside the old folder would be left behind with it.
        let rescued = BundledPsyNeuView.rescueUserModels(fromTree: current)
        if !rescued.isEmpty {
            logCollector.add(
                "Moved \(rescued.count) saved model(s) to "
                    + "\(BundledPsyNeuView.userModelsDirectory().path): \(rescued.joined(separator: ", "))",
                source: .system)
        }

        preferences.repoPath = newTree
        appState.repoPath = newTree
        pendingBundledCleanup = current
        recordMoveOutcome(
            "moved from \(treeVersion ?? "an unstamped install") at \(current.path) "
            + "to PsyNeuView \(version) at \(newTree.path)")
        logCollector.add(
            "Now running PsyNeuView \(version) from \(newTree.path). "
                + "The previous install is kept at \(current.path).",
            source: .system)
        showStartingWindow()
        startServices()
    }

    /// After a move to the included version has started and answered (#186),
    /// move the older included folders to the Trash, keeping the one in use
    /// and the one moved from (#239). What happened to each goes in the
    /// launch log. The rules are `BundledCleanup.plan`'s.
    @MainActor
    func removeOlderIncludedVersions() {
        guard let movedFrom = pendingBundledCleanup,
              let inUse = appState.repoPath else { return }
        pendingBundledCleanup = nil
        let support = BundledPsyNeuView.supportDirectory()
        let saved = preferences.repoPath
        Task { @MainActor [weak self] in
            // Off the main thread: listing old trees can take a moment.
            let lines = await Task.detached { () -> [String] in
                let entries = BundledCleanup.plan(
                    folders: BundledCleanup.survey(support: support, inUse: inUse),
                    inUse: inUse, savedInstall: saved, movedFrom: movedFrom)
                guard entries.contains(where: { $0.verdict == .remove }) else { return [] }
                return BundledCleanup.apply(entries)
            }.value
            guard !lines.isEmpty else { return }
            self?.logCollector.add(
                "Removing older included PsyNeuView versions from \(support.path):\n"
                    + lines.joined(separator: "\n"),
                source: .system)
        }
    }

    /// The pip arguments for a new environment that keep the PsyNeuLink in
    /// use in `leaving` (#9): what pip installed there, else the app's record.
    /// The record is brought into step at the same time, and the choice logged.
    func pnlPipArgsKeepingLiveSource(leaving: URL?) -> [String] {
        guard let live = LivePsyNeuLink.read(environmentOf: leaving) else {
            logCollector.add(
                "Installing PsyNeuLink from the saved choice (\(preferences.pnlSourceDescription)).",
                source: .system)
            return preferences.pnlPipArgs
        }
        if let changed = LivePsyNeuLink.reconcile(preferences, with: live) {
            logCollector.add(changed, source: .system)
        }
        logCollector.add(
            "Installing the PsyNeuLink in use (\(live.description)), kept from the previous environment.",
            source: .system)
        return live.pipArgs
    }

    /// Where PsyNeuLink comes from, for About and the self-check: the live
    /// install when it can be read (#9), else the app's record.
    func livePsyNeuLinkDescription() -> String {
        reconcilePsyNeuLinkRecord(repoPath: appState.repoPath ?? preferences.repoPath)
        return preferences.pnlSourceDescription
    }

    /// Bring the app's PsyNeuLink record in step with the environment at
    /// `repoPath` (#9). Called at every start and by the page after a switch.
    @discardableResult
    func reconcilePsyNeuLinkRecord(repoPath: URL?) -> String? {
        guard let live = LivePsyNeuLink.read(environmentOf: repoPath),
              let changed = LivePsyNeuLink.reconcile(preferences, with: live) else { return nil }
        logCollector.add(changed, source: .system)
        return changed
    }

    /// Why preparing the included PsyNeuView failed, for the log and the user.
    struct PrepareFailure: Error {
        let message: String
    }

    /// Unpack the PsyNeuView this app carries, if it isn't already, and build
    /// its Python environment if it has none. Shared by the move after an app
    /// update (#186) and by switching to it in Settings (#195).
    @MainActor
    func prepareIncludedPsyNeuView() async -> Result<URL, PrepareFailure> {
        let tree: URL
        startupProgress?.begin(.getPsyNeuView)
        do {
            tree = try await BundledPsyNeuView.ensureUnpacked { [weak self] line in
                self?.logCollector.add(line, source: .system)
            }
        } catch {
            startupProgress?.fail(.getPsyNeuView, reason: "unpacking failed")
            return .failure(PrepareFailure(message: "unpacking failed: \(error.localizedDescription)"))
        }
        startupProgress?.finish(.getPsyNeuView)

        if !BundledPsyNeuView.hasUsableEnvironment(at: tree) {
            let installer = Installer()
            installer.onOutput = { [weak self] text in
                self?.logCollector.add(text, source: .system)
            }
            installer.onStepChange = { [weak self] step, status in
                self?.startupProgress?.apply(step, status)
            }
            installer.onDetail = { [weak self] step, detail in
                self?.startupProgress?.note(detail, under: ProgressStep(step))
            }
            // Install the PsyNeuLink that is actually in use in the environment
            // being left, not the app's record of what it was set up with: a
            // switch made in the page's Settings never reached that record, and
            // building from it moved people off their own checkout (#9).
            let pipArgs = pnlPipArgsKeepingLiveSource(leaving: preferences.repoPath)
            let built = await installer.repairEnvironment(
                repoPath: tree, pnlPipArgs: pipArgs)
            guard built, BundledPsyNeuView.hasUsableEnvironment(at: tree) else {
                return .failure(PrepareFailure(message: "installing its Python packages failed"))
            }
        }
        return .success(tree)
    }

    /// Switch to another PsyNeuView install, chosen in Settings (#195).
    ///
    /// Stop, switch, start. Nothing is deleted: the install left behind stays
    /// where it is, and switching back is the same choice. If the switch can't
    /// be made, the install in use starts again and the user is told why — the
    /// app must never be left running nothing.
    func switchInstall(_ decision: InstallSwitch.Decision) {
        let previous = preferences.repoPath
        let target: String
        switch decision {
        case .useBundled(let version): target = "PsyNeuView \(version), included with this app"
        case .useCheckout(let path): target = "your checkout at \(InstallSwitch.abbreviated(path))"
        case .nothingToDo, .refuse: return
        }
        logCollector.add(
            "Switching PsyNeuView: from \(InstallSwitch.describeRunning(previous)) to \(target).",
            source: .system)

        // Keep the checkout being left on the list, so switching back is a pick.
        if let previous, InstallSwitch.kind(of: InstallSwitch.facts(at: previous)) == .checkout {
            preferences.recentCheckouts = InstallSwitch.remembering(
                previous.path, in: preferences.recentCheckouts)
        }

        // Windows point at the old server; a new one opens once the switch
        // is up. Closed while services still run, so closing doesn't quit.
        switch decision {
        case .useBundled: beginProgress(ProgressPlan.steps(for: .update))
        default: startupProgress = nil
        }
        showStartingWindow(status: "Switching to \(target)…")
        for window in appWindows { window.close() }
        appWindows.removeAll()
        processManager.stopAll()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))

            let newTree: URL
            switch decision {
            case .useBundled:
                switch await self.prepareIncludedPsyNeuView() {
                case .failure(let reason):
                    self.logCollector.add(
                        "Couldn't switch to \(target) (\(reason.message)). "
                            + "Starting the install already in use.",
                        source: .system, isError: true)
                    let alert = NSAlert()
                    alert.messageText = "Couldn't switch PsyNeuView"
                    alert.informativeText = "Switching to \(target) failed: \(reason.message). "
                        + "The install you had is starting again; nothing was changed. "
                        + "The log window has the details."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    self.startupProgress = nil
                    self.showStartingWindow()
                    self.startServices()
                    return
                case .success(let tree):
                    newTree = tree
                }
                // Models saved inside an included install's folder would be
                // left behind with it (PsyNeuView-archive#1089).
                if let previous,
                   case .bundled = InstallSwitch.kind(of: InstallSwitch.facts(at: previous)) {
                    BundledPsyNeuView.rescueUserModels(fromTree: previous)
                }
                self.preferences.useBundledApp = true
            case .useCheckout(let path):
                newTree = URL(fileURLWithPath: path)
                self.preferences.recentCheckouts = InstallSwitch.remembering(
                    path, in: self.preferences.recentCheckouts)
                // Branch switching and code updates apply to a checkout.
                self.preferences.useBundledApp = false
            case .nothingToDo, .refuse:
                return
            }

            self.preferences.repoPath = newTree
            self.appState.repoPath = newTree
            self.setupCompleted = true
            self.logCollector.add(
                "Now running \(InstallSwitch.describeRunning(newTree)). "
                    + (previous.map { "The previous install is kept at \($0.path)." } ?? ""),
                source: .system)
            self.showStartingWindow()
            self.startServices()
        }
    }

    @objc func showSetupWizard() {
        if let window = setupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wizardView = SetupWizardView(
            preferences: preferences,
            onComplete: { [weak self] in
                guard let self else { return }
                self.setupCompleted = true
                self.appState.repoPath = self.preferences.repoPath
                // A window must exist before the wizard closes, or macOS quits the
                // app. It used to be the log window, which meant a successful
                // install ended on a debug log with no sign the app was coming.
                // (#96)
                self.showStartingWindow()
                self.setupWindow?.close()
                self.setupWindow = nil
                // Now start services
                self.startServices()
            }
        )
        let hostingView = NSHostingView(rootView: wizardView)

        // Native on purpose (PsyNeuView-archive#1279): runs before any PsyNeuView is installed.
        let window = NSWindow(
            // Resizable, at the size the wizard asks for: fixed at 640×480 it
            // hid Get Started once a checkout's folder field appeared (#193).
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "PsyNeuView — Setup"
        window.contentMinSize = NSSize(width: 700, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        setupWindow = window
    }

    @objc func quitApp() {
        processManager.stopAllSync()
        NSApp.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

@MainActor
extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if appWindows.contains(where: { $0 === window }) {
            appWindows.removeAll(where: { $0 === window })
        } else if window === startingWindow {
            // Clear the reference, or a later showStartingWindow() would try to
            // raise a window that is already gone. (#96)
            startingWindow = nil
        } else if window === logWindow {
            logWindow = nil
        } else if window === setupWindow {
            setupWindow = nil
            // If setup wizard was closed without completing (user didn't click Launch),
            // and no services are running, quit the app entirely
            if !setupCompleted && !appState.canStop {
                quitApp()
                return
            }
        }

        // Quit the app when all windows are closed (no reason to linger)
        if appWindows.isEmpty && startingWindow == nil && logWindow == nil
            && setupWindow == nil
            && !appState.canStop {
            quitApp()
        }
    }
}
