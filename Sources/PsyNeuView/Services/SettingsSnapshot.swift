import Foundation

/// Every app setting, for Report a Problem (#208).
///
/// A screenshot of the wrong Settings, or a Open menu with four sections,
/// is explained by settings nobody thought to ask about: which PsyNeuView
/// runs, which PsyNeuLink and from where, whether developer mode is on. So
/// the report carries all of them, as `report.md` lines and as a
/// `diagnostics.json` section.
///
/// Scope: the app's own settings, the system and the installs, and nothing
/// else. Tokens never appear (none are settings; `redact` catches any that
/// got into a path or repo name). The "Send to" address is personal, so it
/// is reported as default or custom, never quoted. Page preferences are
/// listed by key name only (#218): the values are the user's. The home
/// folder is shown as `~`.
///
/// `Values` is read from `Preferences` in the app; the tests build one by
/// hand, so `dictionary` and `lines` are pure.
enum SettingsSnapshot {

    /// Sparkle's record of app-update checks, when it has one.
    struct UpdateCheck: Equatable {
        var lastCheck: Date?
        var automatic: Bool
        /// Seconds between automatic checks.
        var interval: TimeInterval?
    }

    /// What `Preferences` holds, plus the few settings kept elsewhere.
    struct Values: Equatable {
        // Preferences
        var repoPath: String?
        var useBundledApp: Bool
        var branch: String
        var autoRestart: Bool
        var launchAtLogin: Bool
        var developerMode: Bool
        var pnlSource: String
        var pnlBranch: String
        var pnlRepo: String
        var pnlLocalPath: String
        var pnlUpdateOffersMuted: Bool
        var recentCheckouts: [String]
        var reportSendWith: String
        var reportSendTo: String
        var lastMoveOutcome: String
        var tooOldOfferDismissed: String
        // Elsewhere
        /// `PortChecker.rememberedPort`: the port the backend last used.
        var lastBackendPort: Int?
        /// `PagePreferencesStore.keys` (#218): names only.
        var pagePreferenceKeys: [String]
        var updateCheck: UpdateCheck?
    }

    /// The setting's value as the report says it. A custom address is never
    /// quoted: it's personal, and the team doesn't need it to read the report.
    static func sendToDescription(_ sendTo: String) -> String {
        let address = sendTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty || address.caseInsensitiveCompare(ReportDefaults.contactEmail) == .orderedSame {
            return "default (\(ReportDefaults.contactEmail))"
        }
        return "a custom address (not included)"
    }

    /// Readable lines for `report.md`, redacted. The order follows the
    /// Settings screen: the install, then the app's own, then PsyNeuLink.
    static func lines(_ v: Values, home: String = NSHomeDirectory(),
                      timeZone: TimeZone = .current) -> [String] {
        let r = { (s: String) in ProblemReport.redact(s, home: home) }
        let onOff = { (b: Bool) in b ? "on" : "off" }
        var lines: [String] = []
        lines.append("PsyNeuView runs from: " + (v.useBundledApp ? "the included PsyNeuView" : "a checkout"))
        lines.append("PsyNeuView checkout path: " + (v.repoPath.map(r) ?? "none"))
        lines.append("PsyNeuView branch: " + r(v.branch))
        lines.append("Recent checkouts: " + (v.recentCheckouts.isEmpty ? "none" : v.recentCheckouts.map(r).joined(separator: ", ")))
        lines.append("Auto-restart: " + onOff(v.autoRestart))
        lines.append("Launch at login: " + onOff(v.launchAtLogin))
        lines.append("Developer mode: " + onOff(v.developerMode))
        lines.append("PsyNeuLink source: " + r(v.pnlSource))
        lines.append("PsyNeuLink branch: " + r(v.pnlBranch))
        lines.append("PsyNeuLink repo: " + (v.pnlRepo.isEmpty ? "default (\(PsyNeuLinkSource.defaultRepo))" : r(v.pnlRepo)))
        lines.append("PsyNeuLink local checkout: " + (v.pnlLocalPath.isEmpty ? "none" : r(v.pnlLocalPath)))
        lines.append("PsyNeuLink update offers: " + (v.pnlUpdateOffersMuted ? "muted" : "shown"))
        lines.append("Send reports with: " + r(v.reportSendWith))
        lines.append("Send reports to: " + sendToDescription(v.reportSendTo))
        lines.append("Last move to the included PsyNeuView: " + (v.lastMoveOutcome.isEmpty ? "none tried" : r(v.lastMoveOutcome)))
        lines.append("Too-old offer dismissed for: " + (v.tooOldOfferDismissed.isEmpty ? "nothing" : r(v.tooOldOfferDismissed)))
        lines.append("Last backend port: " + (v.lastBackendPort.map(String.init) ?? "none remembered"))
        lines.append(ProblemReport.pagePreferencesLine(v.pagePreferenceKeys.map(r)))
        lines.append("App update checks: " + updateCheckDescription(v.updateCheck, timeZone: timeZone))
        return lines
    }

    /// The `settings` section of `diagnostics.json`, redacted. Keys are the
    /// `Preferences` names, so a line in the log and a key here match.
    static func dictionary(_ v: Values, home: String = NSHomeDirectory(),
                           timeZone: TimeZone = .current) -> [String: Any] {
        let r = { (s: String) in ProblemReport.redact(s, home: home) }
        var d: [String: Any] = [
            "repoPath": v.repoPath.map(r) ?? NSNull(),
            "useBundledApp": v.useBundledApp,
            "branch": r(v.branch),
            "autoRestart": v.autoRestart,
            "launchAtLogin": v.launchAtLogin,
            "developerMode": v.developerMode,
            "pnlSource": r(v.pnlSource),
            "pnlBranch": r(v.pnlBranch),
            "pnlRepo": r(v.pnlRepo),
            "pnlLocalPath": r(v.pnlLocalPath),
            "pnlUpdateOffersMuted": v.pnlUpdateOffersMuted,
            "recentCheckouts": v.recentCheckouts.map(r),
            "reportSendWith": r(v.reportSendWith),
            "reportSendTo": sendToDescription(v.reportSendTo),
            "lastMoveOutcome": r(v.lastMoveOutcome),
            "tooOldOfferDismissed": r(v.tooOldOfferDismissed),
            "lastBackendPort": v.lastBackendPort ?? NSNull(),
            "pagePreferences": ["count": v.pagePreferenceKeys.count, "keys": v.pagePreferenceKeys.map(r)] as [String: Any],
        ]
        if let u = v.updateCheck {
            d["appUpdateCheck"] = [
                "lastCheck": u.lastCheck.map { timestamp($0, timeZone: timeZone) } ?? NSNull(),
                "automatic": u.automatic,
                "intervalSeconds": u.interval ?? NSNull(),
            ] as [String: Any]
        } else {
            d["appUpdateCheck"] = NSNull()
        }
        return d
    }

    static func updateCheckDescription(_ u: UpdateCheck?, timeZone: TimeZone) -> String {
        guard let u else { return "not available" }
        var s = u.automatic ? "automatic" : "manual only"
        if u.automatic, let interval = u.interval, interval > 0 {
            s += " every \(Int(interval / 3600)) h"
        }
        s += ", last checked " + (u.lastCheck.map { timestamp($0, timeZone: timeZone) } ?? "never")
        return s
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

extension Preferences {
    /// Everything in Preferences, for the report. The rest of
    /// `SettingsSnapshot.Values` is filled in by the app.
    func snapshotValues(lastBackendPort: Int?, pagePreferenceKeys: [String],
                        updateCheck: SettingsSnapshot.UpdateCheck?) -> SettingsSnapshot.Values {
        SettingsSnapshot.Values(
            repoPath: repoPath?.path,
            useBundledApp: useBundledApp,
            branch: branch,
            autoRestart: autoRestart,
            launchAtLogin: launchAtLogin,
            developerMode: developerMode,
            pnlSource: pnlSource.rawValue,
            pnlBranch: pnlBranch,
            pnlRepo: pnlRepo,
            pnlLocalPath: pnlLocalPath,
            pnlUpdateOffersMuted: pnlUpdateOffersMuted,
            recentCheckouts: recentCheckouts,
            reportSendWith: reportSendWith,
            reportSendTo: reportSendTo,
            lastMoveOutcome: lastMoveOutcome,
            tooOldOfferDismissed: tooOldOfferDismissed,
            lastBackendPort: lastBackendPort,
            pagePreferenceKeys: pagePreferenceKeys,
            updateCheck: updateCheck)
    }
}
