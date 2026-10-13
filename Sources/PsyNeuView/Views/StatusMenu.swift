import AppKit

@MainActor
final class StatusMenu {
    private let menu = NSMenu()
    private let appState: AppState
    private weak var appDelegate: AppDelegate?

    // Menu item references for updating
    private var statusItem: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var newWindowItem: NSMenuItem!

    init(appState: AppState, appDelegate: AppDelegate) {
        self.appState = appState
        self.appDelegate = appDelegate
        buildMenu()
    }

    var nsMenu: NSMenu { menu }

    func update() {
        statusItem.title = "\(appState.backendStatus.statusDot) Server: \(appState.backendStatus.displayName)"

        startItem.isEnabled = appState.canStart
        stopItem.isEnabled = appState.canStop
        restartItem.isEnabled = appState.canStop
        newWindowItem.isEnabled = appState.isRunning
    }

    private func buildMenu() {
        // Header
        let header = NSMenuItem(title: AppIdentity.current.displayName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: AppIdentity.current.displayName,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(header)
        menu.addItem(.separator())

        // Status
        statusItem = NSMenuItem(
            title: "\(appState.backendStatus.statusDot) Server: \(appState.backendStatus.displayName)",
            action: nil, keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // New Window
        newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(AppDelegate.showAppWindow),
            keyEquivalent: "n"
        )
        newWindowItem.target = appDelegate
        newWindowItem.isEnabled = false
        menu.addItem(newWindowItem)

        menu.addItem(.separator())

        // Start
        startItem = NSMenuItem(
            title: "Start",
            action: #selector(AppDelegate.startServices),
            keyEquivalent: "s"
        )
        startItem.target = appDelegate
        menu.addItem(startItem)

        // Stop
        stopItem = NSMenuItem(
            title: "Stop",
            action: #selector(AppDelegate.stopServices),
            keyEquivalent: "x"
        )
        stopItem.target = appDelegate
        stopItem.isEnabled = false
        menu.addItem(stopItem)

        // Restart
        restartItem = NSMenuItem(
            title: "Restart",
            action: #selector(AppDelegate.restartServices),
            keyEquivalent: "r"
        )
        restartItem.target = appDelegate
        restartItem.isEnabled = false
        menu.addItem(restartItem)

        menu.addItem(.separator())

        // View Logs
        let logsItem = NSMenuItem(
            title: "View Logs...",
            action: #selector(AppDelegate.showLogWindow),
            keyEquivalent: "l"
        )
        logsItem.target = appDelegate
        menu.addItem(logsItem)

        // Settings: PsyNeuView's, in the app window (#200)
        let prefsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.showSettings),
            keyEquivalent: ","
        )
        prefsItem.target = appDelegate
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit PsyNeuView",
            action: #selector(AppDelegate.quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = appDelegate
        menu.addItem(quitItem)
    }
}
