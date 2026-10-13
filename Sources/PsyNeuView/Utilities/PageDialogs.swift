import Foundation

/// What the page's `alert()`, `confirm()` and `prompt()` dialogs say and return
/// (#243).
///
/// WKWebView shows none of these by itself: without the matching `WKUIDelegate`
/// methods, `confirm()` answers false and `prompt()` answers null at once, with
/// nothing on screen. So PsyNeuView's "You have unsaved changes that will be
/// lost. Load anyway?" cancelled every open in the app, silently. The app window
/// now shows them as alerts; this holds the parts that don't need AppKit, so
/// they can be unit-tested.
enum PageDialogs {
    /// The alert's title. The page's own text goes underneath it.
    static let title = "PsyNeuView"

    /// The buttons, first one the default (Return).
    static let alertButtons = ["OK"]
    static let confirmButtons = ["OK", "Cancel"]

    /// What `confirm()` returns: true only for OK, the first button.
    static func confirmResult(pressedFirstButton: Bool) -> Bool {
        pressedFirstButton
    }

    /// What `prompt()` returns: the typed text for OK (even when empty, as in a
    /// browser), null for Cancel.
    static func promptResult(pressedFirstButton: Bool, text: String) -> String? {
        pressedFirstButton ? text : nil
    }
}
