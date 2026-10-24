import Foundation

/// PsyNeuView itself, shipped inside the app.
///
/// Cloning at install time required the user to be a collaborator on a private
/// repository. The GitHub App work (#63) narrowed what the app can do with an
/// account, but it could not remove that gate: a user access token is limited to
/// the intersection of the app's permissions and the *user's* own, so a
/// non-collaborator authorises successfully and then 404s on the clone.
///
/// Bundling removes the gate outright, and collapses two update mechanisms into
/// one — a new PsyNeuView is now a new app release, rather than a separate
/// code-update step users never knew to run (#47). (#74, under #26)
///
/// The archive is staged at build time by `scripts/fetch-psyneuview.sh`, which
/// also builds the frontend — which is why no user ever needs Node (#65).
enum BundledPsyNeuView {

    /// Unpacked alongside the app's other data, **not** left inside the app
    /// bundle: Sparkle replaces the bundle wholesale on update, so anything
    /// inside it is destroyed, and the venv records an absolute path into this
    /// tree that has to survive (#66).
    ///
    /// `~/Library/Application Support/PsyNeuView`, or `PsyNeuView-Test` for
    /// the test app (#209): the folder is the identity's, so the two apps
    /// never unpack over each other.
    static func supportDirectory(identity: AppIdentity = .current) -> URL {
        identity.supportDirectory()
    }

    /// Where the app used to keep a user's own models, and where a rescue still
    /// puts them.
    ///
    /// Deliberately outside the unpacked tree. PsyNeuView's models/ directory is
    /// both the model-discovery folder *and* where Save As writes — and in a
    /// bundled install that folder sits inside the tree, which this app treats as
    /// disposable: ensureUnpacked deletes and re-extracts it when it looks
    /// incomplete, and a new bundled version unpacks somewhere else entirely.
    ///
    /// So work saved through Save As was sitting in storage the app is entitled
    /// to throw away. A tester reported a saved model that went missing.
    /// (jonhanke-nam/PsyNeuView-archive#1089)
    ///
    /// Since #212 the app no longer tells the backend to use this folder:
    /// PsyNeuView picks the project folder itself (PsyNeuView-archive#1295), and knows
    /// this path as a *legacy* folder — one that holds models stays the project
    /// folder, with a one-time offer to move it to the visible default under
    /// ~/Documents. That is exactly why `rescueUserModels` still moves into it:
    /// anything rescued here is found by the backend and offered a move,
    /// rather than vanishing from the Open menu.
    static func userModelsDirectory(identity: AppIdentity = .current) -> URL {
        identity.userModelsDirectory()
    }

    /// Whether `tree` is a folder this app unpacked and may replace, which is
    /// the only kind models need rescuing from (#199).
    ///
    /// The rescue exists because a bundled install's folder is app-owned
    /// storage that updates replace (PsyNeuView-archive#1089). It ran on every folder,
    /// though, so launching from a developer checkout moved the user's own
    /// models out of it. Now: inside the app's support directory, and not a
    /// git checkout.
    static func isAppOwnedTree(_ tree: URL, supportDirectory support: URL = supportDirectory()) -> Bool {
        let path = tree.standardizedFileURL.resolvingSymlinksInPath().path
        let root = support.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { return false }
        return !FileManager.default.fileExists(atPath: tree.appendingPathComponent(".git").path)
    }

    /// Move any user models out of the tree and into durable storage.
    ///
    /// The archive ships only README files under `models/`, so every `.py` found
    /// there was written by the user — through Save As, which until now wrote
    /// into storage this app deletes. Returns the names rescued, so the caller
    /// can say what happened rather than moving someone's work silently.
    ///
    /// Existing files at the destination are never overwritten: a name clash
    /// keeps both, since the wrong one to lose is the one already saved.
    /// (jonhanke-nam/PsyNeuView-archive#1089)
    @discardableResult
    static func rescueUserModels(
        fromTree tree: URL, supportDirectory support: URL = supportDirectory()
    ) -> [String] {
        // Only an app-owned folder is at risk; a checkout's models/ is the
        // user's own and stays where they put it (#199).
        guard isAppOwnedTree(tree, supportDirectory: support) else { return [] }
        let fm = FileManager.default
        let source = tree.appendingPathComponent("models")
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: nil) else { return [] }

        let destination = userModelsDirectory()
        var rescued: [String] = []
        for case let file as URL in walker where file.pathExtension == "py" {
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                var target = destination.appendingPathComponent(file.lastPathComponent)
                var attempt = 2
                while fm.fileExists(atPath: target.path) {
                    let stem = file.deletingPathExtension().lastPathComponent
                    target = destination.appendingPathComponent("\(stem)-\(attempt).py")
                    attempt += 1
                }
                try fm.moveItem(at: file, to: target)
                rescued.append(target.lastPathComponent)
            } catch {
                // A file we cannot move is left where it is: losing it to a
                // failed rescue would be worse than leaving it at risk.
                continue
            }
        }
        return rescued
    }

    /// The staged archive inside the app bundle, if this build has one.
    ///
    /// A developer build that hasn't run `make psyneuview-bundle` has none, and
    /// the app falls back to the clone path.
    static func archiveURL(in bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: resources, includingPropertiesForKeys: nil)
        else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("psyneuview-")
                   && $0.lastPathComponent.hasSuffix(".tar.gz") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    /// `psyneuview-0.0.0-dev.463bd6f.tar.gz` -> `0.0.0-dev.463bd6f`
    ///
    /// Pure, so the naming contract with `fetch-psyneuview.sh` is testable.
    static func version(fromArchiveName name: String) -> String? {
        guard name.hasPrefix("psyneuview-"), name.hasSuffix(".tar.gz") else { return nil }
        let version = name.dropFirst("psyneuview-".count).dropLast(".tar.gz".count)
        return version.isEmpty ? nil : String(version)
    }

    /// Where a given version unpacks to.
    static func installDirectory(version: String) -> URL {
        supportDirectory().appendingPathComponent("psyneuview-\(version)")
    }

    /// What PsyNeuView version an unpacked tree holds, from the BUNDLED_VERSION
    /// file `fetch-psyneuview.sh` writes.
    ///
    /// The app's own version no longer mirrors this — they move at different
    /// rates, and 0.5.2 shipped five launcher changes against zero PsyNeuView
    /// changes (jonhanke-nam/PsyNeuView-archive#1073). So "which PsyNeuView is this?"
    /// has to be answerable some other way, which is this. (#57)
    static func installedVersion(at directory: URL) -> String? {
        stampValue("version", at: directory)
    }

    /// When the PsyNeuView in an unpacked tree was released: the `released=`
    /// line `fetch-psyneuview.sh` writes, the date of the commit its tag
    /// points to (#15). Nil for a tree from before #15, or when the lookup
    /// failed at build time.
    static func installedReleaseDate(at directory: URL) -> Date? {
        guard let value = stampValue("released", at: directory) else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    /// One `key=value` line of BUNDLED_VERSION, or nil if absent or empty.
    static func stampValue(_ key: String, at directory: URL) -> String? {
        let stamp = directory.appendingPathComponent("BUNDLED_VERSION")
        guard let contents = try? String(contentsOf: stamp, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") where line.hasPrefix("\(key)=") {
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Whether the Python environment inside a tree is usable.
    ///
    /// Separate from `isRunnableTree`: the source can be perfectly intact while
    /// the environment is missing, which is exactly what a 0.5.2 user hit — the
    /// app found the tree, found no venv, logged "run the Setup Wizard" and
    /// stopped. (#106)
    static func hasUsableEnvironment(at directory: URL) -> Bool {
        let fm = FileManager.default
        let venv = directory.appendingPathComponent("backend/.venv")
        return fm.isExecutableFile(atPath: venv.appendingPathComponent("bin/python").path)
            && fm.isExecutableFile(atPath: venv.appendingPathComponent("bin/pip").path)
    }

    /// Whether the app can start from this directory, whichever shape it is.
    ///
    /// A clone has a Makefile; a bundled tree deliberately does not — the Makefile
    /// drives venv creation, npm and the dev servers, none of which a bundled
    /// install uses, and shipping it would imply it works. Checking only for a
    /// Makefile is what made 0.5.0 refuse to start from its own bundled tree.
    /// (#89)
    static func isRunnableTree(at directory: URL) -> Bool {
        isUsable(at: directory)
            || FileManager.default.isReadableFile(
                atPath: directory.appendingPathComponent("Makefile").path)
    }

    /// What is already sitting in the directory the user picked.
    ///
    /// The install writes `backend/.venv` into this folder and installs
    /// dependencies there. Doing that on request is reasonable; doing it
    /// silently is not — and the two cases need different things said (#69,
    /// #131).
    enum ExistingContents: Equatable {
        /// Empty, or does not exist yet. Nothing to warn about.
        case clear
        /// Already a PsyNeuView checkout. Adopting it is the intended path for
        /// developers, but it will not be left exactly as it was found.
        case psyNeuViewCheckout
        /// Something else entirely. `~/Documents/PsyNeuView` is a plausible
        /// name for a person to have used for their own files long before
        /// installing this, and that folder used to be installed into without
        /// a word (#131).
        case otherFiles
    }

    /// Inspect the target directory. Never throws: an unreadable directory is
    /// reported as `.clear` so a permissions problem surfaces later, from the
    /// install itself, rather than as a warning about contents we cannot see.
    static func existingContents(at directory: URL) -> ExistingContents {
        let fm = FileManager.default

        if fm.fileExists(atPath: directory.appendingPathComponent("Makefile").path) {
            return .psyNeuViewCheckout
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return .clear
        }
        // .DS_Store and friends are not "someone's files" in any sense the user
        // would recognise, and warning about them would train people to click
        // through the warning that matters.
        let meaningful = entries.filter { !$0.hasPrefix(".") }
        return meaningful.isEmpty ? .clear : .otherFiles
    }

    /// Whether a directory the user picked is already a PsyNeuView checkout that
    /// the installer would adopt rather than clone into.
    ///
    /// Adopting means creating `backend/.venv` inside someone's working tree and
    /// installing dependencies there. That is a reasonable thing to do on
    /// request, and an unreasonable thing to do silently — some users are
    /// PsyNeuView developers. (#69)
    static func wouldAdoptExistingCheckout(at directory: URL) -> Bool {
        existingContents(at: directory) == .psyNeuViewCheckout
    }

    /// Whether branch switching should be offered.
    ///
    /// It operates on a git checkout, so it is meaningless when PsyNeuView came
    /// bundled with the app — there is no branch to switch, and updates arrive
    /// through Sparkle rather than `git checkout`. (#75)
    static func offersBranchSwitching(useBundledApp: Bool, hasBundledArchive: Bool) -> Bool {
        !(useBundledApp && hasBundledArchive)
    }

    /// A tree is only usable if it has the pieces the app actually runs.
    /// A half-extracted archive — interrupted unpack, full disk — must not read
    /// as installed.
    static func isUsable(at directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent("backend/app/main.py").path)
            && fm.fileExists(atPath: directory.appendingPathComponent("frontend/dist/index.html").path)
    }

    enum BundleError: LocalizedError {
        case noArchive
        case unnamedArchive(String)
        case extractionFailed(String)
        case incomplete(URL)

        var errorDescription: String? {
            switch self {
            case .noArchive:
                return "This build has no bundled PsyNeuView. Run `make psyneuview-bundle`, "
                     + "or choose a PsyNeuView checkout in Settings ▸ Mac app instead."
            case .unnamedArchive(let name):
                return "Couldn't read a version from the bundled archive name '\(name)'."
            case .extractionFailed(let detail):
                return "Couldn't unpack the bundled PsyNeuView: \(detail)"
            case .incomplete(let url):
                return "The unpacked PsyNeuView at \(url.path) is missing files. Delete it and re-run setup."
            }
        }
    }

    /// Unpack the bundled archive if it isn't already in place, and return the
    /// directory to use. A tree that is already complete is left alone.
    @discardableResult
    static func ensureUnpacked(log: (String) -> Void = { _ in }) async throws -> URL {
        guard let archive = archiveURL() else { throw BundleError.noArchive }
        let name = archive.lastPathComponent
        guard let version = version(fromArchiveName: name) else {
            throw BundleError.unnamedArchive(name)
        }

        let destination = installDirectory(version: version)
        if isUsable(at: destination) {
            log("  ✓ PsyNeuView \(version) already unpacked")
            return destination
        }

        // A directory that exists but isn't usable is a previous failed unpack.
        // Clear it rather than extracting on top of it.
        if FileManager.default.fileExists(atPath: destination.path) {
            log("  Removing an incomplete PsyNeuView \(version)...")
            try? FileManager.default.removeItem(at: destination)
        }

        let parent = supportDirectory()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        log("Unpacking PsyNeuView \(version)...")
        let result = try? await Shell.run(
            "/usr/bin/tar",
            arguments: ["xzf", archive.path, "-C", parent.path])
        guard let result, result.exitCode == 0 else {
            throw BundleError.extractionFailed(result?.stderr ?? "tar failed")
        }
        guard isUsable(at: destination) else { throw BundleError.incomplete(destination) }

        log("  ✓ PsyNeuView \(version) unpacked to \(destination.path)")
        return destination
    }
}
