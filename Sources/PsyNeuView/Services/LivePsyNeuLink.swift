import Foundation

/// The PsyNeuLink actually installed in a PsyNeuView environment, read from
/// pip's own record on disk (issue #9).
///
/// The app also keeps a record of the source it was set up with
/// (`Preferences.pnlSource` and friends), but a switch made in the page's
/// Settings goes through the backend and never touched that record. Building
/// a new environment from the stale record, as the move to a newer included
/// PsyNeuView did, quietly put a user who had switched to their own checkout
/// back on GitHub `devel`. What pip installed is the truth, so moves, repairs
/// and the record itself follow it.
///
/// Pure parsing is separated from the file access so the rules can be tested
/// without an environment on disk.
struct LivePsyNeuLink: Equatable {
    var source: PsyNeuLinkSource
    /// GitHub branch or ref asked for (`requested_revision`), for `.github`.
    var branch: String = "devel"
    /// `owner/repo` for `.github`; empty means the Princeton default.
    var repo: String = ""
    /// The checkout folder, for `.local` (an editable install).
    var localPath: String = ""
    /// The installed version, from the package metadata, when known.
    var version: String?

    /// What to give pip to install the same thing again.
    ///
    /// A PyPI install keeps its exact version: an official release chosen in
    /// Settings must not turn into "the newest release" on the next move.
    var pipArgs: [String] {
        if source == .pypi, let version, !version.isEmpty {
            return ["psyneulink==\(version)"]
        }
        return source.pipInstallArgs(branch: branch, repo: repo, localPath: localPath)
    }

    /// One line for logs and reports, matching `Preferences.pnlSourceDescription`.
    var description: String {
        switch source {
        case .pypi: return "pypi" + (version.map { "==\($0)" } ?? "")
        case .github: return "github:\(repo.isEmpty ? "" : repo + "@")\(branch)"
        case .local: return "local:\(localPath)"
        }
    }

    // MARK: Parsing (pure)

    /// Interpret pip's `direct_url.json` (PEP 610) and the metadata version.
    ///
    /// - An editable install of a folder → `.local` with that folder.
    /// - A git install from GitHub → `.github` with its repo and requested ref.
    /// - No `direct_url.json` but an installed package → `.pypi`.
    /// Anything else (an unreadable record, a non-GitHub git host, a plain
    /// local wheel) → nil, so callers fall back to the app's record.
    static func parse(directURL: Data?, version: String?) -> LivePsyNeuLink? {
        guard let directURL else {
            // No direct_url.json: installed from an index, i.e. PyPI.
            return version == nil ? nil : LivePsyNeuLink(source: .pypi, version: version)
        }
        guard let object = try? JSONSerialization.jsonObject(with: directURL) as? [String: Any],
              let url = object["url"] as? String else { return nil }

        if let dirInfo = object["dir_info"] as? [String: Any],
           dirInfo["editable"] as? Bool == true,
           let path = fileURLPath(url) {
            return LivePsyNeuLink(source: .local, localPath: path, version: version)
        }

        if let vcs = object["vcs_info"] as? [String: Any], vcs["vcs"] as? String == "git",
           let repo = githubRepo(url) {
            let ref = (vcs["requested_revision"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "devel"
            return LivePsyNeuLink(
                source: .github, branch: ref,
                repo: repo == PsyNeuLinkSource.defaultRepo ? "" : repo, version: version)
        }
        return nil
    }

    /// `file:///Users/x/PsyNeuLink` → `/Users/x/PsyNeuLink` (percent-decoded).
    static func fileURLPath(_ url: String) -> String? {
        guard url.hasPrefix("file://"), let parsed = URL(string: url), parsed.isFileURL else { return nil }
        let path = parsed.path
        return path.isEmpty ? nil : path
    }

    /// `https://github.com/Owner/Repo.git` (or `git@github.com:Owner/Repo`) → `Owner/Repo`.
    static func githubRepo(_ url: String) -> String? {
        var rest: Substring
        if let range = url.range(of: "github.com/") {
            rest = url[range.upperBound...]
        } else if let range = url.range(of: "github.com:") {
            rest = url[range.upperBound...]
        } else {
            return nil
        }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// The `Version:` line of a dist-info `METADATA` file.
    static func version(fromMetadata text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("Version:") {
            let v = line.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    // MARK: Reading an environment

    /// The PsyNeuLink installed in `<repo>/backend/.venv`, or nil when there is
    /// no environment, no PsyNeuLink in it, or its record can't be read.
    static func read(environmentOf repo: URL?) -> LivePsyNeuLink? {
        guard let repo else { return nil }
        let lib = repo.appendingPathComponent("backend/.venv/lib")
        let fm = FileManager.default
        guard let pythons = try? fm.contentsOfDirectory(atPath: lib.path) else { return nil }
        for python in pythons.sorted().reversed() where python.hasPrefix("python") {
            let site = lib.appendingPathComponent(python).appendingPathComponent("site-packages")
            guard let entries = try? fm.contentsOfDirectory(atPath: site.path) else { continue }
            guard let info = entries.first(where: {
                $0.lowercased().hasPrefix("psyneulink-") && $0.hasSuffix(".dist-info")
            }) else { continue }
            let dir = site.appendingPathComponent(info)
            let direct = try? Data(contentsOf: dir.appendingPathComponent("direct_url.json"))
            let metadata = (try? String(contentsOf: dir.appendingPathComponent("METADATA"), encoding: .utf8))
                .flatMap(version(fromMetadata:))
            return parse(directURL: direct, version: metadata)
        }
        return nil
    }

    // MARK: Keeping the app's record in step

    /// Make the app's record describe `live`. Returns a line saying what
    /// changed, or nil when the record already agreed.
    @discardableResult
    static func reconcile(_ preferences: Preferences, with live: LivePsyNeuLink) -> String? {
        let before = preferences.pnlSourceDescription
        switch live.source {
        case .local:
            guard preferences.pnlSource != .local || preferences.pnlLocalPath != live.localPath else { return nil }
            preferences.pnlLocalPath = live.localPath
            preferences.pnlSource = .local
        case .github:
            guard preferences.pnlSource != .github || preferences.pnlBranch != live.branch
                    || preferences.pnlRepo != live.repo else { return nil }
            preferences.pnlRepo = live.repo
            preferences.pnlBranch = live.branch
            preferences.pnlSource = .github
        case .pypi:
            guard preferences.pnlSource != .pypi else { return nil }
            preferences.pnlSource = .pypi
        }
        return "PsyNeuLink record updated to match what is installed: \(before) → \(preferences.pnlSourceDescription)"
    }
}
