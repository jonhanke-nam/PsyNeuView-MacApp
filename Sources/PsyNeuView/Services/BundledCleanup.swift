import Foundation

/// Removing the older included PsyNeuView folders an update leaves behind
/// (#239).
///
/// Each included PsyNeuView unpacks into its own
/// `…/Application Support/PsyNeuView/psyneuview-<version>`, Python environment
/// and all, and nothing ever removed one: since launches started moving to the
/// version the app carries (#186), every app update left another behind. One
/// Mac still had an unused `psyneuview-0.5.8`.
///
/// After a launch has moved to the included version *and* the server answered,
/// the older folders go to the Trash — all but the one in use and the one moved
/// from, which stays as a fallback. Only folders the app itself unpacked are
/// ever candidates, and anything that might hold a person's files is kept.
///
/// `plan` is the whole decision and is pure; `survey` and `apply` are the
/// small filesystem part around it.
enum BundledCleanup {

    /// What `survey` found about one `psyneuview-<version>` folder.
    struct Folder: Equatable {
        var url: URL
        /// The version stamped in BUNDLED_VERSION, which only a tree unpacked
        /// from the app's archive carries.
        var stampedVersion: String?
        /// Has `.git` or a Makefile: someone's checkout, never the app's (#195).
        var isCheckout: Bool
        /// A symbolic link, not a folder: never followed, never removed.
        var isSymlink: Bool = false
        /// Files that look like a person's work and that the version in use
        /// does not ship: saved models under `models/`, and working copies of
        /// included models that PsyNeuView kept in `backend/` before
        /// PsyNeuView-archive#1319 and could not move out (a conflict leaves them
        /// where they are). Relative to the folder.
        var leftoverFiles: [String] = []
    }

    enum Verdict: Equatable {
        case remove
        case keep(String)
    }

    struct Entry: Equatable {
        var url: URL
        var verdict: Verdict
    }

    /// `psyneuview-0.5.8` -> `0.5.8`; nil for any other name.
    static func version(fromFolderName name: String) -> String? {
        guard name.hasPrefix("psyneuview-") else { return nil }
        let version = String(name.dropFirst("psyneuview-".count))
        return version.isEmpty ? nil : version
    }

    /// Decide what happens to each folder.
    ///
    /// - Parameters:
    ///   - folders: what `survey` found in the support directory.
    ///   - inUse: the folder the server was just started from.
    ///   - savedInstall: the folder the saved preference points to.
    ///   - movedFrom: the folder this launch moved away from (#186), kept as
    ///     the fallback. When it is not among `folders` (it was somewhere
    ///     else, or already gone) the newest older version is kept instead.
    /// - Returns: one entry per folder named `psyneuview-<version>`, in the
    ///   order given; anything else is not the app's and is not listed.
    static func plan(
        folders: [Folder], inUse: URL, savedInstall: URL?, movedFrom: URL?
    ) -> [Entry] {
        let inUsePath = canonical(inUse)
        let savedPath = savedInstall.map(canonical)
        let movedFromPath = movedFrom.map(canonical)
        let fallbackIsHere = movedFromPath.map { p in folders.contains { canonical($0.url) == p } } ?? false

        var entries: [Entry] = []
        for folder in folders {
            guard let nameVersion = version(fromFolderName: folder.url.lastPathComponent) else { continue }
            let path = canonical(folder.url)
            let verdict: Verdict
            if path == inUsePath {
                verdict = .keep("in use")
            } else if path == savedPath {
                verdict = .keep("the saved install")
            } else if path == movedFromPath {
                verdict = .keep("the previous version, kept as a fallback")
            } else if folder.isSymlink {
                verdict = .keep("a link, not a folder the app unpacked")
            } else if folder.isCheckout {
                verdict = .keep("a checkout")
            } else if folder.stampedVersion == nil {
                verdict = .keep("no BUNDLED_VERSION stamp, so not one the app unpacked")
            } else if folder.stampedVersion != nameVersion {
                verdict = .keep("its BUNDLED_VERSION doesn't match its name")
            } else if !folder.leftoverFiles.isEmpty {
                verdict = .keep("holds files that may be yours: "
                                + folder.leftoverFiles.sorted().joined(separator: ", "))
            } else {
                verdict = .remove
            }
            entries.append(Entry(url: folder.url, verdict: verdict))
        }

        // No fallback among these yet: keep the newest of the ones that would
        // go, so one older version always remains to go back to.
        if !fallbackIsHere {
            let removable = entries.indices.filter { entries[$0].verdict == .remove }
            let newest = removable.max { a, b in
                let va = version(fromFolderName: entries[a].url.lastPathComponent) ?? ""
                let vb = version(fromFolderName: entries[b].url.lastPathComponent) ?? ""
                return va.compare(vb, options: .numeric) == .orderedAscending
            }
            if let newest {
                entries[newest].verdict = .keep("the newest previous version, kept as a fallback")
            }
        }
        return entries
    }

    /// The suffixes of the files a person's work consists of: models and the
    /// layout, label and index files PsyNeuView writes beside them.
    static let workFileSuffixes = [".py", ".pnlview.json", ".labels.yaml", ".psyneuview.json"]

    /// The work-like files in an old tree that the tree in use doesn't ship.
    ///
    /// Pure: the caller lists the files. `oldBackend` and `shippedBackend` are
    /// the names directly in `backend/` (and in `backend/.psyneuview/`, as
    /// `.psyneuview/<name>`) of the old tree and of the one in use;
    /// `oldModels` is every file under the old tree's `models/`, relative to
    /// it. The archive ships only READMEs under `models/`, so any work file
    /// there is someone's; in `backend/`, anything the current version also
    /// ships is the app's own.
    static func leftovers(
        oldBackend: [String], shippedBackend: Set<String>, oldModels: [String]
    ) -> [String] {
        func isWork(_ name: String) -> Bool {
            workFileSuffixes.contains { name.hasSuffix($0) }
        }
        let backend = oldBackend
            .filter { isWork($0) && !shippedBackend.contains($0) }
            .map { "backend/\($0)" }
        let models = oldModels.filter(isWork).map { "models/\($0)" }
        return backend + models
    }

    // MARK: The filesystem part

    /// Look at every `psyneuview-<version>` entry in `support`.
    static func survey(support: URL, inUse: URL) -> [Folder] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: support, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        else { return [] }
        let shipped = Set(backendFiles(in: inUse))
        return entries
            .filter { version(fromFolderName: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> Folder? in
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                let isSymlink = values?.isSymbolicLink ?? false
                guard isSymlink || (values?.isDirectory ?? false) else { return nil }
                if isSymlink {
                    return Folder(url: url, stampedVersion: nil, isCheckout: false, isSymlink: true)
                }
                let facts = InstallSwitch.facts(at: url)
                return Folder(
                    url: url,
                    stampedVersion: BundledPsyNeuView.installedVersion(at: url),
                    isCheckout: InstallSwitch.kind(of: facts) == .checkout,
                    leftoverFiles: leftovers(
                        oldBackend: backendFiles(in: url),
                        shippedBackend: shipped,
                        oldModels: filesUnder(url.appendingPathComponent("models"))))
            }
    }

    /// Names directly in `backend/`, and in `backend/.psyneuview/` prefixed
    /// with `.psyneuview/`.
    private static func backendFiles(in tree: URL) -> [String] {
        let fm = FileManager.default
        let backend = tree.appendingPathComponent("backend")
        let top = (try? fm.contentsOfDirectory(atPath: backend.path)) ?? []
        let dot = (try? fm.contentsOfDirectory(
            atPath: backend.appendingPathComponent(".psyneuview").path)) ?? []
        return top + dot.map { ".psyneuview/\($0)" }
    }

    /// Every file under `folder`, relative to it. An unreadable folder reads
    /// as unreadable, not empty: it is reported as a leftover, so the tree
    /// is kept rather than removed unseen.
    private static func filesUnder(_ folder: URL) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [] }
        guard let walker = fm.enumerator(atPath: folder.path) else { return ["(unreadable).py"] }
        var out: [String] = []
        while let rel = walker.nextObject() as? String { out.append(rel) }
        return out
    }

    /// Move the folders the plan removes to the Trash, so a mistake can be
    /// undone from Finder. Returns one line per folder for the launch log.
    static func apply(_ entries: [Entry]) -> [String] {
        let fm = FileManager.default
        return entries.map { entry in
            let name = entry.url.lastPathComponent
            switch entry.verdict {
            case .keep(let why):
                return "  kept \(name): \(why)"
            case .remove:
                do {
                    try fm.trashItem(at: entry.url, resultingItemURL: nil)
                    return "  moved \(name) to the Trash"
                } catch {
                    return "  couldn't remove \(name), left in place: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
