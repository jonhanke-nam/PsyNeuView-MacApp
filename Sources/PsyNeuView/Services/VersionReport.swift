import Foundation

/// What's actually installed, for the About panel and for bug reports.
///
/// Three versions matter and they move independently:
///
/// - **the app** — this launcher, versioned on its own since
///   jonhanke-nam/PsyNeuView-archive#1073
/// - **PsyNeuView** — bundled with the app, recorded in BUNDLED_VERSION (#57)
/// - **PsyNeuLink** — *not* bundled. Installed at first run from PyPI by
///   default, or from a branch of PrincetonUniversity/PsyNeuLink, or a local
///   checkout, depending on Preferences.
///
/// Before this, "which versions are you running?" needed three different places
/// to answer, and the PsyNeuLink one had no answer in the UI at all.
enum VersionReport {

    /// Extract a version from a `.dist-info` directory name.
    ///
    /// `psyneulink-0.19.1.0+10.g83cc4165b7.dist-info` -> `0.19.1.0+10.g83cc4165b7`
    ///
    /// Reading the directory name avoids importing the package: importing
    /// PsyNeuLink takes seconds, which is far too slow for opening a menu.
    static func version(fromDistInfo name: String, package: String) -> String? {
        guard name.hasSuffix(".dist-info") else { return nil }
        let stem = String(name.dropLast(".dist-info".count))
        // Distribution names normalise `-` to `_` on disk, so compare both forms.
        let wanted = package.lowercased()
        let prefixes = [wanted + "-", wanted.replacingOccurrences(of: "-", with: "_") + "-"]
        guard prefixes.contains(where: { stem.lowercased().hasPrefix($0) }),
              let dash = stem.firstIndex(of: "-") else { return nil }
        let version = String(stem[stem.index(after: dash)...])
        return version.isEmpty ? nil : version
    }

    /// The installed version of a package inside a venv, or nil if absent.
    static func installedVersion(of package: String, inVenv venv: URL) -> String? {
        let fm = FileManager.default
        let lib = venv.appendingPathComponent("lib")
        guard let pythonDirs = try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)
        else { return nil }
        for pythonDir in pythonDirs where pythonDir.lastPathComponent.hasPrefix("python") {
            let sitePackages = pythonDir.appendingPathComponent("site-packages")
            guard let entries = try? fm.contentsOfDirectory(at: sitePackages, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries {
                if let found = version(fromDistInfo: entry.lastPathComponent, package: package) {
                    return found
                }
            }
        }
        return nil
    }

    /// PsyNeuLink checkouts the app keeps for alternative sources, named by
    /// their owner. `~/.psyneuview/sources/PsyNeuLink-PrincetonUniversity`
    /// reports as `PrincetonUniversity`.
    static func availablePsyNeuLinkSources(
        in root: URL = AppIdentity.current.cloneRoot()
    ) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .map { $0.lastPathComponent }
            .filter { $0.hasPrefix("PsyNeuLink-") }
            .map { String($0.dropFirst("PsyNeuLink-".count)) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// The lines shown in the About panel, in the order they appear.
    ///
    /// Assembled as a pure function so the wording and the fallbacks are
    /// testable without a running app.
    ///
    /// `identity`, `buildCommit`, `bundlePath` and `dataFolder` say which
    /// copy this is (#209): the first line names a test build as one, with
    /// the commit it was built from, and the last lines say where the app
    /// runs from and where its data is — the two things that tell a test
    /// install from a real one when both are on the same Mac.
    static func aboutLines(
        appVersion: String,
        appBuild: String?,
        psyNeuViewVersion: String?,
        checkoutPath: String?,
        checkoutBranch: String? = nil,
        psyNeuLinkVersion: String?,
        psyNeuLinkSource: String?,
        availableSources: [String],
        identity: AppIdentity = .release,
        buildCommit: String? = nil,
        bundlePath: String? = nil,
        dataFolder: String? = nil
    ) -> [String] {
        var lines: [String] = []

        var first = "\(identity.displayName) app \(appVersion)"
        if let appBuild, appBuild != appVersion {
            first += " (build \(appBuild))"
        }
        if let buildCommit, !buildCommit.isEmpty {
            first += ", built from commit \(buildCommit)"
        }
        if identity.isTest {
            first += " — a test build (\(identity.bundleIdentifier))"
        }
        lines.append(first)

        if let psyNeuViewVersion {
            lines.append("PsyNeuView \(psyNeuViewVersion), included with this app")
        } else if let checkoutPath {
            // Which checkout and which branch: the two things a bug report
            // about a checkout needs, and what #195 asks About to say.
            if let checkoutBranch {
                lines.append("PsyNeuView from your checkout at \(checkoutPath), on branch \(checkoutBranch)")
            } else {
                lines.append("PsyNeuView from your checkout at \(checkoutPath)")
            }
        } else {
            lines.append("PsyNeuView not installed yet")
        }

        // Named as not-bundled on purpose: it is fetched at install time, and
        // which source it came from changes what you are running.
        if let psyNeuLinkVersion {
            if let psyNeuLinkSource {
                lines.append("PsyNeuLink \(psyNeuLinkVersion), installed from \(psyNeuLinkSource)")
            } else {
                lines.append("PsyNeuLink \(psyNeuLinkVersion)")
            }
        } else {
            lines.append("PsyNeuLink not installed yet")
        }

        if !availableSources.isEmpty {
            lines.append("Other PsyNeuLink sources available: "
                         + availableSources.joined(separator: ", "))
        }

        if let bundlePath, !bundlePath.isEmpty {
            lines.append("Running from \(bundlePath)")
        }
        if let dataFolder, !dataFolder.isEmpty {
            lines.append("Data in \(dataFolder); settings under \(identity.bundleIdentifier)")
        }

        return lines
    }

    /// The short commit the app was built from, stamped into Info.plist as
    /// `PNVBuildCommit` by `make app` and `make test-app` (#209); nil for a
    /// `swift run` build.
    static func buildCommit(in bundle: Bundle = .main) -> String? {
        guard let commit = bundle.infoDictionary?["PNVBuildCommit"] as? String else { return nil }
        let trimmed = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
