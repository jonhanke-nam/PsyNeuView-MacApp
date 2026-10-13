import Foundation
import ServiceManagement

/// The app's side of the `pnvSettings` bridge (#200): the stored preferences,
/// the login item, and switching installs (#195).
@MainActor
final class AppSettingsHost: SettingsBridgeHost {
    let preferences: Preferences
    /// The process manager follows auto-restart as soon as it changes.
    var onAutoRestartChanged: ((Bool) -> Void)?
    /// The App menu shows or hides its developer item as soon as the mode
    /// changes (#214).
    var onDeveloperModeChanged: ((Bool) -> Void)?
    /// Stops PsyNeuView, switches to the chosen install and starts it. The
    /// services belong to the app delegate, so it does this.
    var onSwitchInstall: ((InstallSwitch.Decision) -> Void)?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var autoRestart: Bool { preferences.autoRestart }
    var launchAtLogin: Bool { preferences.launchAtLogin }
    var developerMode: Bool { preferences.developerMode }

    func setAutoRestart(_ on: Bool) {
        preferences.autoRestart = on
        onAutoRestartChanged?(on)
    }

    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Said, not swallowed: the old window ticked the box and silently
            // did nothing when macOS refused.
            return "macOS didn't change the login item: \(error.localizedDescription)"
        }
        preferences.launchAtLogin = on
        return nil
    }

    func setDeveloperMode(_ on: Bool) {
        preferences.developerMode = on
        onDeveloperModeChanged?(on)
    }

    var reportSendWith: String { preferences.reportSendWith }
    var reportSendTo: String { preferences.reportSendTo }

    func setReportSendWith(_ route: String) {
        preferences.reportSendWith = route
    }

    func setReportSendTo(_ address: String) {
        preferences.reportSendTo = address
    }

    /// The version this app carries, if this build has one.
    private var archiveVersion: String? {
        BundledPsyNeuView.archiveURL()
            .flatMap { BundledPsyNeuView.version(fromArchiveName: $0.lastPathComponent) }
    }

    func installState() -> SettingsBridge.InstallState {
        let current = preferences.repoPath
        let choice = InstallSwitch.choice(
            currentPath: current?.path, current: current.map(InstallSwitch.facts(at:)))
        // Checkouts used before, with the one running now at the front.
        var recent = preferences.recentCheckouts
        if let current, InstallSwitch.kind(of: InstallSwitch.facts(at: current)) == .checkout {
            recent = InstallSwitch.remembering(current.path, in: recent)
        }
        return SettingsBridge.InstallState(
            running: InstallSwitch.describeRunning(current),
            choice: choice,
            includedVersion: archiveVersion,
            recentCheckouts: recent)
    }

    func decide(_ choice: InstallSwitch.Choice) -> InstallSwitch.Decision {
        let current = preferences.repoPath
        var target: InstallSwitch.Facts?
        if case .checkout(let path) = choice {
            target = InstallSwitch.facts(at: URL(fileURLWithPath: InstallSwitch.normalized(path)))
        }
        return InstallSwitch.decide(
            choice: choice,
            currentPath: current?.path,
            current: current.map(InstallSwitch.facts(at:)),
            archiveVersion: archiveVersion,
            target: target)
    }

    func switchInstall(_ decision: InstallSwitch.Decision) {
        onSwitchInstall?(decision)
    }
}
