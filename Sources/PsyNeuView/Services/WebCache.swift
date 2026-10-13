import Foundation
import WebKit

/// The window's HTTP cache, cleared when what the page is built from changes (#1).
///
/// The app reuses the last backend port so the page keeps its preferences
/// (PsyNeuView-MacApp-archive#218), which also keeps its origin, and with it
/// WebKit's HTTP cache, across launches and updates. After an update the
/// window could then show the previous version's cached page: a user on the
/// new PsyNeuView had no Autosave checkbox, because the page was the old one.
///
/// So before a window loads the page, compare a stamp of the app and the
/// PsyNeuView it runs with the one from last time, and if they differ, drop
/// only the disk and memory caches. Local storage, cookies and everything else
/// stay. With no stamp on record (the first launch of a version that has this),
/// the cache is cleared too, which is what fixes a page that is already stale:
/// installing the update is enough.
enum WebCache {
    static let stampKey = "webCacheStamp"

    /// The two cache types removed. Nothing else.
    static let clearedTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]

    /// What the page is built from: the app version, the PsyNeuView version it
    /// runs and, for a checkout, the commit it is on.
    static func stamp(appVersion: String, psyneuviewVersion: String?, checkoutHead: String?) -> String {
        "app=\(appVersion);psyneuview=\(psyneuviewVersion ?? "?");head=\(checkoutHead ?? "-")"
    }

    /// Clear when nothing is on record, and whenever the stamp changed.
    static func shouldClear(last: String?, current: String) -> Bool {
        guard let last, !last.isEmpty else { return true }
        return last != current
    }

    /// The stamp for this launch.
    static func currentStamp(repoPath: URL?, info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let version = repoPath.flatMap { BundledPsyNeuView.installedVersion(at: $0) }
        let head = repoPath.flatMap { headCommit(of: $0) }
        return stamp(appVersion: "\(short) (\(build))", psyneuviewVersion: version, checkoutHead: head)
    }

    /// The commit a git checkout is on, read from `.git` without running git.
    /// Nil for a bundled tree (no `.git`) or anything unreadable.
    static func headCommit(of repo: URL) -> String? {
        let git = repo.appendingPathComponent(".git")
        guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty
        else { return nil }
        guard head.hasPrefix("ref: ") else { return head }
        let ref = String(head.dropFirst("ref: ".count))
        if let loose = try? String(contentsOf: git.appendingPathComponent(ref), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !loose.isEmpty {
            return loose
        }
        if let packed = try? String(contentsOf: git.appendingPathComponent("packed-refs"), encoding: .utf8) {
            for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
                return String(line.split(separator: " ")[0])
            }
        }
        return nil
    }

    /// Clear the caches if the stamp changed, then call `then` on the main
    /// thread. The new stamp is recorded only after the caches are gone.
    static func clearIfNeeded(
        repoPath: URL?, defaults: UserDefaults = .standard,
        log: @escaping (String) -> Void, then: @escaping () -> Void
    ) {
        let current = currentStamp(repoPath: repoPath)
        let last = defaults.string(forKey: stampKey)
        guard shouldClear(last: last, current: current) else {
            then()
            return
        }
        WKWebsiteDataStore.default().removeData(ofTypes: clearedTypes, modifiedSince: .distantPast) {
            defaults.set(current, forKey: stampKey)
            log(last == nil
                ? "Cleared the window's web cache (first launch of this version)."
                : "Cleared the window's web cache: the app or PsyNeuView changed (\(last!) → \(current)).")
            DispatchQueue.main.async(execute: then)
        }
    }
}
