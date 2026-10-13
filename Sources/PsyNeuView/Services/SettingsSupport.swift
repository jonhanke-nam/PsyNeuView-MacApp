import Foundation

/// Whether the PsyNeuView in use has the Settings this app relies on (#205).
///
/// Since #200 there is no native Settings window: ⌘, asks PsyNeuView's page to
/// open its Settings, and the settings only this app can act on — which
/// install runs, auto-restart, opening at login, problem reports — live in its
/// "Mac app" section. A PsyNeuView older than `minimumVersion` has neither,
/// so ⌘, would open nothing and the gear would show Settings without that
/// section: no way left to switch installs. The app has to say so itself, and
/// offer the switch, because the page can't.
///
/// The rules are pure functions; `version(at:)` is the one place that reads
/// the disk.
enum SettingsSupport {

    /// The first PsyNeuView whose Settings has the Mac app section
    /// (jonhanke-nam/PsyNeuView-archive#1282, released in 0.5.9).
    static let minimumVersion = "0.5.9"

    enum Verdict: Equatable {
        case supported
        case tooOld(version: String)
        /// The version couldn't be read, or is a development build's
        /// `0.0.0-dev.<sha>`, which says nothing about its age. Unknown is
        /// treated as supported: the offer is for an install known to be old.
        case unknown
    }

    static func verdict(version: String?) -> Verdict {
        guard let version, !version.isEmpty, !version.hasPrefix("0.0.0") else { return .unknown }
        guard version.first?.isNumber == true else { return .unknown }
        return SemanticVersion.isAtLeast(version, minimum: minimumVersion)
            ? .supported : .tooOld(version: version)
    }

    static func isTooOld(_ version: String?) -> Bool {
        if case .tooOld = verdict(version: version) { return true }
        return false
    }

    /// What the dialog offers for an install that's too old.
    struct Offer: Equatable {
        var title: String
        var message: String
        /// The included PsyNeuView to switch to, when this app carries one new
        /// enough. Nil leaves only Report a Problem.
        var switchToVersion: String?
    }

    /// - Parameters:
    ///   - version: the old version running.
    ///   - running: `InstallSwitch.describeRunning`, e.g. "Your PsyNeuView
    ///     checkout at ~/code/PsyNeuView, on branch devel".
    ///   - isCheckout: whether that install is a checkout.
    ///   - archiveVersion: the PsyNeuView this app carries, if any.
    static func offer(
        version: String, running: String, isCheckout: Bool, archiveVersion: String?
    ) -> Offer {
        var message = "This app is running PsyNeuView \(version) (\(running)). "
            + "The app's Settings, including choosing which PsyNeuView runs, need "
            + "PsyNeuView \(minimumVersion) or later."
        var switchTo: String?
        if let archiveVersion, !isTooOld(archiveVersion) {
            switchTo = archiveVersion
            message += "\n\nSwitch to PsyNeuView \(archiveVersion), included with this app. "
                + (isCheckout
                    ? "Your checkout stays where it is, and you can switch back to it in Settings."
                    : "Nothing is deleted.")
        }
        if isCheckout {
            message += "\n\nOr update your checkout (git pull on its branch) and restart the app."
        }
        if switchTo == nil && !isCheckout {
            message += "\n\nReport a Problem collects what's needed to sort this out."
        }
        return Offer(
            title: "This PsyNeuView is too old for the app's Settings",
            message: message,
            switchToVersion: switchTo)
    }

    /// Remembers "Not Now" for one install at one version, so the offer isn't
    /// repeated at every launch; ⌘, still shows it. A new version of the same
    /// install asks again.
    static func dismissalKey(path: String, version: String) -> String {
        "\(path)|\(version)"
    }

    /// One line for Report a Problem.
    static func reportLine(_ verdict: Verdict) -> String {
        switch verdict {
        case .supported: return "has the Mac app section (\(minimumVersion) or later)"
        case .tooOld(let v): return "too old: \(v) is older than \(minimumVersion), which the app's Settings need"
        case .unknown: return "version unknown"
        }
    }

    // MARK: - Reading the disk

    /// The PsyNeuView version a folder holds: the BUNDLED_VERSION stamp an
    /// install from the app's archive carries, else `__version__` in
    /// `backend/app/__init__.py`, which every PsyNeuView has had since 0.1.0
    /// and which a checkout keeps current.
    static func version(at url: URL) -> String? {
        if let stamped = BundledPsyNeuView.installedVersion(at: url) { return stamped }
        let initPy = url.appendingPathComponent("backend/app/__init__.py")
        guard let source = try? String(contentsOf: initPy, encoding: .utf8) else { return nil }
        return version(fromInitPy: source)
    }

    /// `__version__ = "0.5.9"` -> `0.5.9`. Pure, for tests.
    static func version(fromInitPy source: String) -> String? {
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("__version__") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
