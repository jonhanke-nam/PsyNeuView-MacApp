import Foundation

/// Titles for the two update items in the App menu, and whether the second
/// one is shown at all. (#167, #214)
///
/// They sit next to each other and both say "update", but they act on
/// different things: one replaces the application through Sparkle, the other
/// pulls the PsyNeuView checkout the application runs. Adjacent and
/// identically shaped, the pair asks the reader to already know the
/// difference — and picking the wrong one does something plausible enough not
/// to look wrong.
///
/// The fix is to let each item say what it is at. The app item shows the
/// version Sparkle would replace. The checkout item names the folder it pulls
/// and the branch that folder is on — "~/Documents/PsyNeuView @ devel" — because
/// "Code" on its own was read as PsyNeuLink, and a branch without a folder
/// does not say which repository it belongs to.
///
/// The checkout item is a developer item (#214, PsyNeuView-archive#1291). Checkouts
/// are pulled at every launch, so it only matters mid-session, to someone
/// working in the checkout; everyone else saw a greyed-out item they could
/// neither use nor explain. `showsCodeUpdate` is that rule, kept here so the
/// menu and the tests agree on it.
///
/// Pure, and separate from the menu, so the wording is testable without
/// building a menu — the same reason `MenuShortcuts` exists.
enum UpdateMenuTitles {
    static let appUpdateBase = "Check for App Updates..."
    /// The checkout item with nothing filled in; the detail goes before the
    /// ellipsis, so the item still ends the way a command that asks first does.
    static let codeUpdateBase = "Update PsyNeuView checkout…"

    /// Appends `detail` in parentheses, or returns the title unchanged.
    ///
    /// A missing value means the app could not read it, and an empty
    /// parenthesis is worse than none: it reads as a value that is itself
    /// empty rather than as one that could not be found.
    private static func title(_ base: String, detail: String?) -> String {
        guard let detail = cleaned(detail) else { return base }
        return "\(base) (\(detail))"
    }

    /// `detail` trimmed, or nil when there is nothing in it.
    private static func cleaned(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What Sparkle would be replacing: the version running right now.
    ///
    /// With updates off — the test app (#209) — the item says so instead,
    /// since a disabled "Check for App Updates" on its own reads as broken.
    static func appUpdate(installedVersion: String?, updatesEnabled: Bool = true) -> String {
        guard updatesEnabled else {
            return title("App updates are off in the test app", detail: installedVersion)
        }
        return title(appUpdateBase, detail: installedVersion)
    }

    /// What a checkout update would pull: the folder, shortened with `~` as
    /// people write paths, and the branch it is on.
    ///
    ///     Update PsyNeuView checkout (~/Documents/PsyNeuView @ devel)…
    ///
    /// `tracksGit` is false for a bundled install, where PsyNeuView arrives
    /// with the app and there is no checkout to name. The item is disabled in
    /// that case, and naming a folder and branch it does not have would be a
    /// lie told twice over. A checkout whose branch cannot be read (a detached
    /// HEAD, an unreadable `.git`) is named by its folder alone.
    ///
    /// - Parameters:
    ///   - path: the checkout folder, as stored (not yet abbreviated).
    ///   - branch: the branch that folder is on, from `InstallSwitch.currentBranch`.
    ///   - tracksGit: whether the folder is a git checkout at all.
    ///   - home: the home folder `~` stands for; a parameter so tests can fix it.
    static func codeUpdate(
        path: String?, branch: String?, tracksGit: Bool, home: String = NSHomeDirectory()
    ) -> String {
        guard tracksGit, let path = cleaned(path) else { return codeUpdateBase }
        var detail = InstallSwitch.abbreviated(path, home: home)
        if let branch = cleaned(branch) { detail += " @ \(branch)" }
        // The detail sits before the ellipsis, not after it.
        let stem = String(codeUpdateBase.dropLast())
        return "\(stem) (\(detail))…"
    }

    /// Whether the checkout item is in the menu at all.
    ///
    /// Hidden, not disabled, outside developer mode: a disabled item still
    /// asks to be understood, and there is nothing a regular user can do with
    /// this one. Inside developer mode it is enabled only for a checkout,
    /// which the menu decides separately (`tracksGit`).
    static func showsCodeUpdate(developerMode: Bool) -> Bool {
        developerMode
    }
}
