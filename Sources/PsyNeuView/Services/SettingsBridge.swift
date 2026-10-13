import Foundation

/// What the `pnvSettings` bridge needs from the app (#200). The app's real
/// one is `AppSettingsHost`; tests pass a fake.
@MainActor
protocol SettingsBridgeHost: AnyObject {
    var autoRestart: Bool { get }
    var launchAtLogin: Bool { get }
    var developerMode: Bool { get }
    func setAutoRestart(_ on: Bool)
    /// Nil when done, or why macOS refused.
    func setLaunchAtLogin(_ on: Bool) -> String?
    func setDeveloperMode(_ on: Bool)
    /// Report a Problem's two settings (#202), already checked by the bridge.
    var reportSendWith: String { get }
    var reportSendTo: String { get }
    func setReportSendWith(_ route: String)
    func setReportSendTo(_ address: String)
    func installState() -> SettingsBridge.InstallState
    func decide(_ choice: InstallSwitch.Choice) -> InstallSwitch.Decision
}

/// The `pnvSettings` bridge between PsyNeuView's Settings and the app (#200).
///
/// There is one Settings: PsyNeuView's, in the app window. ⌘, and the gear
/// icon both open it. The settings only the Mac app can act on — which
/// PsyNeuView install runs (#195), auto-restart, launch at login — appear in
/// its "Mac app" section, shown only when this bridge is present, and are read
/// and written through it. Same pattern as `pnvFile` (#28).
///
/// JS contract (frontend half: jonhanke-nam/PsyNeuView, `macAppSettings.ts`).
/// `postMessage` returns a Promise; a malformed message rejects it.
///
///     { op: "get" }                                  -> Snapshot
///     { op: "set", key, value: boolean }             -> Snapshot
///         key: "autoRestart" | "launchAtLogin" | "developerMode"
///     { op: "set", key, value: string }              -> Snapshot
///         key: "reportSendWith" ("ask" | "mail" | "outlook" | "gmail")
///            | "reportSendTo"   (an email address, or "" for none)
///     { op: "checkInstall",  choice: "bundled" | "checkout", path? } -> Verdict
///     { op: "switchInstall", choice: "bundled" | "checkout", path? } -> Verdict
///         (when the verdict is a switch, the app then stops, switches and
///          starts again; the page goes away with the old server)
///
///     Snapshot = { install: { running, choice, checkoutPath, includedVersion,
///                             recentCheckouts }, autoRestart, launchAtLogin,
///                  developerMode, reportSendWith, reportSendTo,
///                  reportSendToDefault }
///         (reportSendToDefault: who reports go to when "Send to" is empty,
///          for the page's placeholder; the page never hard-codes it)
///     Verdict  = { decision: "nothingToDo" | "useBundled" | "useCheckout"
///                            | "refuse", message, path? }
///
/// Events the app sends the page, as window CustomEvents:
///   `pnv:mac-settings-changed` (detail: Snapshot) after any change, so every
///   open window shows the same values; `pnv:open-settings` for ⌘,.
///
/// All message handling is here, as a pure function over a host, so it can
/// be tested without a web view.
enum SettingsBridge {
    static let handlerName = "pnvSettings"

    /// Settings whose home is the "Mac app" section (`settings:mac-app` in
    /// PsyNeuView's docs/settings-inventory.yaml). The policy test checks this
    /// list against its copy of the inventory.
    static let macAppKeys = [
        "install", "autoRestart", "launchAtLogin", "reportSendWith", "reportSendTo",
    ]

    /// How Report a Problem may offer to send a report (#202). "ask" shows
    /// every way; the others lead with one, falling back when it's missing.
    static let reportSendWithChoices = ["ask", "mail", "outlook", "gmail"]

    /// Developer mode's one control is PsyNeuView's Preferences toggle, not
    /// the Mac app section. The app keeps the value for it because the page's
    /// own storage doesn't survive a relaunch inside the app (each launch
    /// serves the page from a new port, so a new origin), and because the app
    /// needs it before the page loads (the backend's `--reload`).
    static let pageOwnedKeys = ["developerMode"]

    static let changedEvent = "pnv:mac-settings-changed"
    static let openSettingsEvent = "pnv:open-settings"

    /// Posted after any change, so every window's page hears about it.
    static let didChange = Notification.Name("PsyNeuView.settingsBridgeDidChange")
    /// Posted by ⌘,; the object is the window whose page should open Settings.
    static let openRequested = Notification.Name("PsyNeuView.openWebSettings")

    struct InstallState: Equatable {
        /// "PsyNeuView 0.5.8, included with this app", or the checkout and branch.
        var running: String
        var choice: InstallSwitch.Choice
        /// The version this app carries, if this build has one.
        var includedVersion: String?
        var recentCheckouts: [String]
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// The reply, and a switch to make once the reply is on its way.
    struct Outcome {
        var reply: Result<[String: Any], Failure>
        var switchTo: InstallSwitch.Decision? = nil
    }

    @MainActor
    static func handle(_ body: Any, host: SettingsBridgeHost) -> Outcome {
        guard let body = body as? [String: Any], let op = body["op"] as? String else {
            return fail("pnvSettings: message must be an object with an 'op' field")
        }
        switch op {
        case "get":
            return Outcome(reply: .success(snapshot(host)))

        case "set":
            guard let key = body["key"] as? String else {
                return fail("pnvSettings: 'set' needs a 'key'")
            }
            // The two report settings are text; everything else is a switch.
            switch key {
            case "reportSendWith":
                guard let value = body["value"] as? String,
                      reportSendWithChoices.contains(value) else {
                    return fail("pnvSettings: 'reportSendWith' takes "
                                + reportSendWithChoices.map { "\"\($0)\"" }.joined(separator: ", "))
                }
                host.setReportSendWith(value)
                return Outcome(reply: .success(snapshot(host)))
            case "reportSendTo":
                guard let raw = body["value"] as? String else {
                    return fail("pnvSettings: 'reportSendTo' takes an email address, or \"\" for none")
                }
                switch emailAddress(raw) {
                case .success(let address): host.setReportSendTo(address)
                case .failure(let why): return Outcome(reply: .failure(why))
                }
                return Outcome(reply: .success(snapshot(host)))
            default:
                break
            }
            guard let value = body["value"] as? Bool else {
                return fail("pnvSettings: '\(key)' takes true or false")
            }
            switch key {
            case "autoRestart":
                host.setAutoRestart(value)
            case "launchAtLogin":
                if let why = host.setLaunchAtLogin(value) { return fail(why) }
            case "developerMode":
                host.setDeveloperMode(value)
            case "install":
                return fail("pnvSettings: switch installs with 'switchInstall'")
            default:
                return fail("pnvSettings: unknown setting '\(key)'")
            }
            return Outcome(reply: .success(snapshot(host)))

        case "checkInstall", "switchInstall":
            guard let choice = choice(from: body) else {
                return fail("pnvSettings: 'choice' must be \"bundled\" or \"checkout\"")
            }
            let decision = host.decide(choice)
            var outcome = Outcome(reply: .success(verdict(decision)))
            if op == "switchInstall" {
                switch decision {
                case .useBundled, .useCheckout: outcome.switchTo = decision
                case .nothingToDo, .refuse: break
                }
            }
            return outcome

        default:
            return fail("pnvSettings: unknown op '\(op)'")
        }
    }

    @MainActor
    static func snapshot(_ host: SettingsBridgeHost) -> [String: Any] {
        let install = host.installState()
        let checkoutPath: Any
        let choiceName: String
        switch install.choice {
        case .bundled:
            choiceName = "bundled"
            checkoutPath = NSNull()
        case .checkout(let path):
            choiceName = "checkout"
            checkoutPath = path
        }
        return [
            "install": [
                "running": install.running,
                "choice": choiceName,
                "checkoutPath": checkoutPath,
                "includedVersion": install.includedVersion ?? NSNull(),
                "recentCheckouts": install.recentCheckouts,
            ] as [String: Any],
            "autoRestart": host.autoRestart,
            "launchAtLogin": host.launchAtLogin,
            "developerMode": host.developerMode,
            "reportSendWith": host.reportSendWith,
            "reportSendTo": host.reportSendTo,
            "reportSendToDefault": ReportDefaults.contactEmail,
        ]
    }

    /// "Send to", trimmed: empty, or one plausible address. Not a full RFC
    /// check — just enough to catch a name or a typo with no `@` before it
    /// lands in every report's email.
    static func emailAddress(_ raw: String) -> Result<String, Failure> {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { return .success("") }
        guard address.range(of: #"^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$"#, options: .regularExpression) != nil else {
            return .failure(Failure(message: "“\(address)” doesn't look like an email address."))
        }
        return .success(address)
    }

    /// What Apply & Restart would do, in words for the Settings row.
    static func verdict(_ decision: InstallSwitch.Decision) -> [String: Any] {
        switch decision {
        case .nothingToDo:
            return ["decision": "nothingToDo", "message": "This is the PsyNeuView running now."]
        case .useBundled(let version):
            return [
                "decision": "useBundled",
                "message": "Apply & Restart switches to PsyNeuView \(version), included with this app.",
            ]
        case .useCheckout(let path):
            return [
                "decision": "useCheckout",
                "message": "Looks like a PsyNeuView checkout. Apply & Restart switches to it.",
                "path": path,
            ]
        case .refuse(let why):
            return ["decision": "refuse", "message": why]
        }
    }

    /// `{choice: "bundled"}` or `{choice: "checkout", path}`. A leading `~`
    /// is the home folder, as people type paths.
    static func choice(from body: [String: Any]) -> InstallSwitch.Choice? {
        switch body["choice"] as? String {
        case "bundled":
            return .bundled
        case "checkout":
            let raw = (body["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .checkout((raw as NSString).expandingTildeInPath)
        default:
            return nil
        }
    }

    /// JS that delivers an event to the page. JSON is valid JS, so the detail
    /// is inlined as a literal.
    static func eventScript(_ name: String, detail: [String: Any]? = nil) -> String {
        var detailJS = "null"
        if let detail,
           let data = try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            detailJS = json
        }
        return "window.dispatchEvent(new CustomEvent(\(quoted(name)), { detail: \(detailJS) }));"
    }

    /// ⌘,. The flag covers a page that hasn't attached its listener yet: the
    /// page checks it when it mounts, and clears it when it opens Settings.
    static var openSettingsScript: String {
        "window.__pnvOpenSettingsRequested = true; " + eventScript(openSettingsEvent)
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func fail(_ message: String) -> Outcome {
        Outcome(reply: .failure(Failure(message: message)))
    }
}
