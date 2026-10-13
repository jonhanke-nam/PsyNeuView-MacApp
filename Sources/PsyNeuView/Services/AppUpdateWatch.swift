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
    /// The update Sparkle found: its version as people read it, and where its
    /// release notes are, if the feed names them.
    struct Found: Equatable {
        var version: String
        var releaseNotesURL: String?
    }

    /// An update is waiting when Sparkle found one newer than what is running.
    /// Sparkle only reports newer items, but a stale finding must not survive
    /// an install: after updating, the running version catches up and the
    /// notice goes away even if the finding is still remembered.
    static func isWaiting(running: String, found: Found?) -> Bool {
        guard let found else { return false }
        return compare(found.version, running) == .orderedDescending
    }

    /// The bridge's `appUpdate` value: `{available, version, releaseNotesURL}`
    /// when an update is waiting, otherwise `{available: false}`. Older pages
    /// ignore the key; older apps never send it.
    static func bridgeValue(running: String, found: Found?) -> [String: Any] {
        guard isWaiting(running: running, found: found), let found else {
            return ["available": false]
        }
        return [
            "available": true,
            "version": found.version,
            "releaseNotesURL": found.releaseNotesURL ?? NSNull(),
        ]
    }

    /// Dotted numeric versions ("0.5.22" < "0.6.0" < "0.6.10"). A part that
    /// isn't a number compares as 0, so "0.6.0-beta" reads as 0.6.0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let parts = { (s: String) -> [Int] in
            s.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == " " })
                .map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let found = AppUpdateWatch.Found(
            version: item.displayVersionString,
            releaseNotesURL: item.releaseNotesURL?.absoluteString)
        DispatchQueue.main.async { self.onChange?(found) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { self.onChange?(nil) }
    }
}
