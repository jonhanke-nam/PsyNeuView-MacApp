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
    static func bridgeValue(running: String, found: Found?) -> [String: Any] {
        guard isWaiting(running: running, found: found), let found else {
            return ["available": false]
        }
        return [
            "available": true,
            "version": found.version,
            "releaseNotesURL": found.releaseNotesURL ?? NSNull(),
            "releasedAt": found.releasedAt.map(iso8601) ?? NSNull(),
            "candidate": found.isCandidate,
        ]
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

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { self.onChange?(nil) }
    }
}
