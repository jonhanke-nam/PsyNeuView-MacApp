import Foundation
import Sparkle

/// Whether an app update is waiting, for the page to say so (#6).
///
/// Sparkle checks every few hours and shows its own alert, but nothing in the
/// window said an update was there: a user stayed on 0.5.20 for days and
/// reported a missing feature that 0.5.22 already had. The page shows a small
/// notice; the app only supplies the state, through the `pnvSettings` bridge
/// (`appUpdate` in its snapshot, `installUpdate` to act on it).
enum AppUpdateWatch {
    /// The update Sparkle found: its version as people read it, where its
    /// release notes are, if the feed names them, and when it was released
    /// (the feed's `<pubDate>`, #15), if the feed says.
    struct Found: Equatable {
        var version: String
        var releaseNotesURL: String?
        var releasedAt: Date? = nil
        /// Posted to the release-candidates channel: a test version, offered
        /// only to people who asked for candidates.
        var isCandidate: Bool = false
    }

    /// The Sparkle channel release candidates are posted to. An appcast item
    /// with `<sparkle:channel>candidates</sparkle:channel>` is invisible to an
    /// updater that does not allow this channel (Sparkle's own filtering), so
    /// people who never turn the setting on never see a candidate.
    static let candidatesChannel = "candidates"

    /// The channels Sparkle may look in. The default channel is always
    /// included by Sparkle itself; an empty set means "default only".
    static func allowedChannels(receiveCandidates: Bool) -> Set<String> {
        receiveCandidates ? [candidatesChannel] : []
    }

    /// Candidate versions are written "0.6.5-rc1" for people (the tag is
    /// v0.6.5-rc1) and "0.6.5rc1" for Sparkle, whose comparator stops reading
    /// at a dash, so to it "0.6.5-rc1" would be the same as "0.6.5" and the
    /// final release would never be offered over its candidate. Without the
    /// dash it reads "0.6.4" < "0.6.5rc1" < "0.6.5rc2" < "0.6.5".
    static func sparkleVersion(_ version: String) -> String {
        version.replacingOccurrences(of: "-", with: "")
    }

    /// An update is waiting when Sparkle found one newer than what is running.
    /// Sparkle only reports newer items, but a stale finding must not survive
    /// an install: after updating, the running version catches up and the
    /// notice goes away even if the finding is still remembered.
    static func isWaiting(running: String, found: Found?) -> Bool {
        guard let found else { return false }
        return compare(found.version, running) == .orderedDescending
    }

    /// The bridge's `appUpdate` value: `{available, version, releaseNotesURL,
    /// releasedAt}` when an update is waiting, otherwise `{available: false}`.
    /// `releasedAt` is an ISO 8601 time in UTC, or null when the feed has no
    /// date (#15). Older pages ignore the keys; older apps never send them.
    ///
    /// `readyToInstall` (#79) is true once the update has downloaded and will
    /// install when the app quits; the page then says so, with Restart now.
    static func bridgeValue(running: String, found: Found?, ready: Bool = false) -> [String: Any] {
        guard isWaiting(running: running, found: found), let found else {
            return ["available": false]
        }
        return [
            "available": true,
            "version": found.version,
            "releaseNotesURL": found.releaseNotesURL ?? NSNull(),
            "releasedAt": found.releasedAt.map(iso8601) ?? NSNull(),
            "candidate": found.isCandidate,
            "readyToInstall": ready,
        ]
    }

    /// The page event for an update that has downloaded and installs on quit
    /// (#79). Detail: `{ version }`. The snapshot's `appUpdate.readyToInstall`
    /// says the same, for a page that loads later.
    static let readyEvent = "pnv:app-update-ready"

    /// How often the app asks for an update while it is open (#79). Sparkle's
    /// own schedule was every 4 hours, and is now off (#81); a release
    /// published in the morning should show the same morning.
    static let periodicCheckInterval: TimeInterval = 60 * 60

    /// Ask "Install PsyNeuView updates automatically when you quit?" (#79)
    /// once, to everyone — new installs and existing users alike — until it
    /// is answered here or the setting is changed in Settings. Consent first:
    /// automatic install is off until someone says yes. Someone who already
    /// has it on (they chose it in Sparkle's own window) made that choice, so
    /// is not asked.
    static func shouldOfferAutoInstall(updatesEnabled: Bool, autoInstall: Bool, asked: Bool) -> Bool {
        updatesEnabled && !asked && !autoInstall
    }

    /// The version this launch updated to, when the last launch ran an older
    /// one (#79): the page says "Updated to X", so nobody wonders why
    /// something changed. A first run (no record) and a downgrade say nothing.
    static func updatedTo(running: String, lastRun: String) -> String? {
        guard !lastRun.isEmpty, compare(running, lastRun) == .orderedDescending else { return nil }
        return running
    }

    /// The bridge's `justUpdated` value: `{ version, releaseNotesURL }`, or
    /// null. The notes link is the one Sparkle's feed gave for that version.
    static func justUpdatedValue(version: String?, notesVersion: String, notesURL: String) -> Any {
        guard let version else { return NSNull() }
        let notes: Any = (notesVersion == version && !notesURL.isEmpty) ? notesURL : NSNull()
        return ["version": version, "releaseNotesURL": notes]
    }

    /// "2026-10-15T18:33:00Z": what the page parses.
    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Versions in Sparkle's own order, so the page agrees with what Sparkle
    /// offers: "0.5.22" < "0.6.0" < "0.6.10", and a release candidate sits
    /// between the release before it and its own final release:
    /// "0.6.4" < "0.6.5-rc1" < "0.6.5-rc2" < "0.6.5".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        SUStandardVersionComparator.default.compareVersion(sparkleVersion(a), toVersion: sparkleVersion(b))
    }

    /// How long after start-up the launch check runs (#74): late enough that
    /// it never competes with opening the window, soon enough that a relaunch
    /// notices a release published minutes ago.
    static let launchCheckDelay: TimeInterval = 5

    // MARK: The app is the only scheduler (#81)

    /// The app's own record of whether it looks for updates on its own (at
    /// launch and hourly). Sparkle's scheduled check is always off (#81): it
    /// ran every 4 hours on its own timer and, with automatic install off,
    /// opened its own modal alert instead of the page's quiet notice.
    static let checkForUpdatesKey = "checkForUpdates"
    /// Sparkle's user-defaults key for its own scheduled checks.
    static let sparkleAutomaticChecksKey = "SUEnableAutomaticChecks"

    /// Whether the app looks for updates on its own. Its own record wins; the
    /// first time, the person's choice in Sparkle carries over (someone who
    /// turned Sparkle's checks off keeps them off); with neither, on.
    static func appChecksForUpdates(stored: Bool?, sparkleStored: Bool?) -> Bool {
        stored ?? sparkleStored ?? true
    }

    /// Take scheduling over from Sparkle, before its updater starts: record
    /// the person's choice in the app's own key (carried over from Sparkle's
    /// the first time) and switch Sparkle's own scheduled check off. Returns
    /// whether the app should look for updates on its own.
    @discardableResult
    static func takeOverScheduling(defaults: UserDefaults) -> Bool {
        let on = appChecksForUpdates(
            stored: defaults.object(forKey: checkForUpdatesKey) as? Bool,
            sparkleStored: defaults.object(forKey: sparkleAutomaticChecksKey) as? Bool)
        defaults.set(on, forKey: checkForUpdatesKey)
        defaults.set(false, forKey: sparkleAutomaticChecksKey)
        return on
    }

    /// Record the person's choice from Settings ▸ General ▸ Updates (#83).
    /// Sparkle's own scheduled check stays off either way: the app is still
    /// the only scheduler, and with this off there are no automatic checks.
    static func setAppChecksForUpdates(_ on: Bool, defaults: UserDefaults) {
        defaults.set(on, forKey: checkForUpdatesKey)
        defaults.set(false, forKey: sparkleAutomaticChecksKey)
    }

    /// What to do with the hourly timer when the switch changes (#83): the
    /// change takes effect at once, not at the next launch.
    enum PeriodicTimerChange: Equatable {
        /// Start the hourly checks, and look once now.
        case start
        /// Stop the hourly checks.
        case stop
        /// Already as asked.
        case keep
    }

    static func periodicTimerChange(timerRunning: Bool, checksOn: Bool) -> PeriodicTimerChange {
        switch (timerRunning, checksOn) {
        case (false, true): return .start
        case (true, false): return .stop
        default: return .keep
        }
    }

    /// Whether Sparkle may run a check (#81). A check the person asked for
    /// ("Check for Updates…", Install in the page) and a quiet
    /// information-only check always may. A background check runs only when
    /// the app asked for it: one Sparkle starts on its own timer could open
    /// its modal alert.
    static func mayCheck(_ kind: SPUUpdateCheck, appAskedForBackgroundCheck: Bool) -> Bool {
        kind != .updatesInBackground || appAskedForBackgroundCheck
    }

    /// What to ask Sparkle at launch (#74).
    enum LaunchCheck: Equatable {
        /// No feed (the test app), or the person turned update checks off:
        /// ask nothing.
        case none
        /// A full background check: finds the newest item on the person's
        /// channels and, with automatic updates on, downloads it to install on
        /// quit. Without automatic updates, Sparkle offers it.
        case background
        /// Only ask the feed what is there, so the page's notice can say so.
        /// For someone who turned Sparkle's automatic checks off: their choice
        /// is not overridden by a check at every launch.
        case informationOnly
    }

    /// Sparkle only checked when its 4-hour interval had passed, so a relaunch
    /// soon after a check never noticed a new release. Every launch now checks,
    /// and every hour after; these are the app's only scheduled checks (#81).
    ///
    /// With automatic install on, a background check downloads the update to
    /// install on quit. Off (the default since #79), a background check would
    /// show Sparkle's own alert; the information-only check lets the page's
    /// quiet notice say an update is there instead. Someone who turned update
    /// checks off gets none (#81).
    static func launchCheck(updatesEnabled: Bool, automaticChecks: Bool, autoInstall: Bool = true) -> LaunchCheck {
        guard updatesEnabled, automaticChecks else { return .none }
        return autoInstall ? .background : .informationOnly
    }

    /// The version this app is.
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

/// Sparkle's delegate, kept only to hear what its checks find. Sparkle holds
/// its delegate weakly, so the app delegate keeps this alive.
final class AppUpdateObserver: NSObject, SPUUpdaterDelegate {
    /// Called on the main thread with the newest finding (nil: none waiting).
    var onChange: ((AppUpdateWatch.Found?) -> Void)?
    /// Whether the person asked for release candidates (Settings > Developer).
    /// Read on every check, so a change takes effect at the next one.
    var receiveCandidates: () -> Bool = { false }
    /// Called on the main thread when an update has downloaded and will
    /// install when the app quits (#79), with the handler that installs it
    /// and relaunches now (Restart now).
    var onReadyToInstall: ((AppUpdateWatch.Found, @escaping () -> Void) -> Void)?

    /// Set by the app just before it starts a background check (#81), and
    /// used up when Sparkle asks whether it may run one. A background check
    /// Sparkle starts on its own is refused, so its modal alert never opens
    /// uninvited.
    var appAskedForBackgroundCheck = false

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let asked = appAskedForBackgroundCheck
        if updateCheck == .updatesInBackground { appAskedForBackgroundCheck = false }
        guard AppUpdateWatch.mayCheck(updateCheck, appAskedForBackgroundCheck: asked) else {
            throw NSError(domain: "PsyNeuView.AppUpdateWatch", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "PsyNeuView schedules its own update checks.",
            ])
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppUpdateWatch.allowedChannels(receiveCandidates: receiveCandidates())
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let found = AppUpdateWatch.Found(
            version: item.displayVersionString,
            releaseNotesURL: item.releaseNotesURL?.absoluteString,
            releasedAt: item.date,
            isCandidate: item.channel == AppUpdateWatch.candidatesChannel)
        DispatchQueue.main.async { self.onChange?(found) }
    }

    /// Taking this over (returning true) keeps Sparkle from asking in its own
    /// window: the page says the update is ready instead (#79). Sparkle still
    /// installs it when the app quits.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let found = AppUpdateWatch.Found(
            version: item.displayVersionString,
            releaseNotesURL: item.releaseNotesURL?.absoluteString,
            releasedAt: item.date,
            isCandidate: item.channel == AppUpdateWatch.candidatesChannel)
        guard let onReadyToInstall else { return false }
        DispatchQueue.main.async { onReadyToInstall(found, immediateInstallHandler) }
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { self.onChange?(nil) }
    }
}
