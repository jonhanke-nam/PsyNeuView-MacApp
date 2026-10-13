import Foundation

/// Links on the page that open a pane of macOS System Settings
/// (jonhanke-nam/PsyNeuView: Settings ▸ General ▸ Walkthrough narration
/// links to Accessibility ▸ Spoken Content, where better voices download).
///
/// A browser hands an `x-apple.systempreferences:` link to macOS. The web
/// view can't load it, and a failed navigation makes the app reload the page,
/// so the navigation delegate opens these with the system instead. Only this
/// scheme: every other link is the web view's as before.
enum SystemSettingsLinks {
    static let scheme = "x-apple.systempreferences"

    /// Whether `url` is a System Settings link to hand to macOS.
    static func opensInSystemSettings(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme
    }
}
