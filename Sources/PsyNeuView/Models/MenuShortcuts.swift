import AppKit

/// The key equivalents the Mac menu claims, as data. (#123)
///
/// The menu is the shell around a web app, and AppKit matches menu key
/// equivalents before the WKWebView sees the event. So every bare Cmd key the
/// menu takes is one the app itself can never use — which is how Cmd+X came to
/// stop the backend instead of cutting a line, and Cmd+S to start services
/// instead of saving a model.
///
/// Declaring them here rather than only inline means the conflict can be
/// checked by a test instead of noticed by a user.
enum MenuShortcuts {
    struct Binding: Equatable {
        let key: String
        let modifiers: NSEvent.ModifierFlags

        init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            self.key = key
            self.modifiers = modifiers
        }

        /// True for a plain Cmd+key, the kind that shadows the web app.
        var isBareCommand: Bool { modifiers == .command }
    }

    // App
    static let updateCode = Binding("u")
    static let settings = Binding(",")
    static let quit = Binding("q")
    // File
    static let newWindow = Binding("n")
    static let closeWindow = Binding("w")
    // Edit — standard, and routed to the web view through the responder chain.
    static let cut = Binding("x")
    static let copy = Binding("c")
    static let paste = Binding("v")
    static let selectAll = Binding("a")
    // Services. Cmd+Ctrl so they do not take Save, Cut or Reload. Stop Services
    // has no shortcut at all: destructive, never urgent.
    static let startServices = Binding("s", [.command, .control])
    static let restartServices = Binding("r", [.command, .control])
    // View — whole-window zoom (#178). ⌘= is the same key as ⌘+ without
    // Shift; both zoom in, as in every browser. The web app claims none of
    // these, and the About window's own zoom keys only apply while it is key.
    static let zoomIn = Binding("+")
    static let zoomInUnshifted = Binding("=")
    static let zoomOut = Binding("-")
    static let actualSize = Binding("0")
    // Window / Development
    static let minimize = Binding("m")
    static let switchBranch = Binding("b")
    static let viewLogs = Binding("l")

    /// Everything the menu claims.
    static let all: [Binding] = [
        updateCode, settings, quit,
        newWindow, closeWindow,
        cut, copy, paste, selectAll,
        startServices, restartServices,
        zoomIn, zoomInUnshifted, zoomOut, actualSize,
        minimize, switchBranch, viewLogs,
    ]

    /// Bare Cmd keys the web app needs, and the menu must therefore leave alone.
    ///
    /// Save and undo already exist in the app; the rest are the shortcuts
    /// planned in PsyNeuView-archive#1112. Listing the planned ones too means the menu
    /// cannot quietly take one back before they are built.
    static let reservedForTheWebApp: Set<String> = [
        "s",  // save the model
        "z",  // undo — model-wide, not just text
        "i",  // show the Inspector
        "o",  // open a model
        "f",  // find in the editor
        "r",  // reload
        "1", "2", "3", "4", "5", "6", "7",  // bottom-panel tabs
    ]

    /// Bare-Cmd bindings that collide with something the web app needs.
    ///
    /// Cut, Copy, Paste and Select All are exempt: those are the standard
    /// system editing commands, and routing them to the web view through the
    /// responder chain is exactly what should happen.
    static var conflicts: [Binding] {
        let systemEditing: Set<String> = ["x", "c", "v", "a"]
        return all.filter {
            $0.isBareCommand
                && reservedForTheWebApp.contains($0.key)
                && !systemEditing.contains($0.key)
        }
    }
}
