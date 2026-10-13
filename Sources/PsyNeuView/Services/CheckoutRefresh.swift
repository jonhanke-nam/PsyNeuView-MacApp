import Foundation

/// What a checkout start has to redo after its pull, and what it can skip
/// (#232).
///
/// Every start of a checkout used to run `npm install` and a full `vite
/// build` whenever a pull brought anything in — a docs commit rebuilt the
/// interface — and the server then re-imported PsyNeuLink behind one
/// spinner. The rules here read the pull's list of changed paths and the
/// state of the tree, and say for each step whether it runs or is skipped,
/// with the reason the checklist shows.
///
/// Pure: facts in, decisions out. `Updater` gathers the facts.
enum CheckoutRefresh {

    /// What the pull and the tree say.
    struct Facts: Equatable, Sendable {
        /// Whether the pull brought commits in. False when the checkout was
        /// already up to date, or the pull could not run (offline, refused).
        var pulled: Bool
        /// The paths the pull changed, relative to the checkout, when known.
        /// Nil means "cannot tell" — a pull with no recorded starting commit
        /// — which reads as "everything may have changed".
        var changedPaths: [String]?
        /// `frontend/node_modules` exists.
        var nodeModulesPresent: Bool
        /// `frontend/dist/index.html` exists.
        var distPresent: Bool
        /// The newest interface source file is newer than the build: edits
        /// made in the checkout by hand, or a pull whose build was interrupted.
        var distOlderThanSources: Bool
    }

    enum Decision: Equatable, Sendable {
        case run(String)
        case skip(String)

        var runs: Bool {
            if case .run = self { return true } else { return false }
        }
        var reason: String {
            switch self {
            case .run(let why), .skip(let why): return why
            }
        }
    }

    struct Plan: Equatable, Sendable {
        var nodePackages: Decision
        var rebuildFrontend: Decision
        var pythonPackages: Decision
    }

    /// Paths under `frontend/` that don't go into the built interface.
    static let frontendExcludedPrefixes = ["frontend/e2e/", "frontend/tests/", "frontend/test/"]
    static let frontendExcludedSuffixes = [".test.ts", ".test.tsx", ".spec.ts", ".spec.tsx", ".md"]

    static func decide(_ facts: Facts) -> Plan {
        Plan(
            nodePackages: nodePackages(facts),
            rebuildFrontend: rebuildFrontend(facts),
            pythonPackages: pythonPackages(facts))
    }

    /// `npm install`: when the package manifest or lock file changed, or
    /// there are no packages at all.
    static func nodePackages(_ facts: Facts) -> Decision {
        if !facts.nodeModulesPresent { return .run("no packages installed yet") }
        guard facts.pulled else { return .skip("nothing new to check") }
        guard let changed = facts.changedPaths else { return .run("can't tell what changed") }
        if changed.contains(where: { $0 == "frontend/package.json" || $0 == "frontend/package-lock.json" }) {
            return .run("package list changed")
        }
        return .skip("no package changes")
    }

    /// `vite build`: when any interface source changed, the build is missing,
    /// or it is older than the sources.
    static func rebuildFrontend(_ facts: Facts) -> Decision {
        if !facts.distPresent { return .run("no built interface yet") }
        if facts.distOlderThanSources { return .run("sources newer than the build") }
        guard facts.pulled else { return .skip("nothing new to build") }
        guard let changed = facts.changedPaths else { return .run("can't tell what changed") }
        if changed.contains(where: isInterfaceSource) { return .run("interface changed") }
        return .skip("no interface changes")
    }

    /// `pip install -e backend/`: only when the backend's project file changed.
    /// Whether its *dependencies* moved is a finer question `Updater` asks
    /// before paying for a reinstall (#144).
    static func pythonPackages(_ facts: Facts) -> Decision {
        guard facts.pulled else { return .skip("no package changes") }
        guard let changed = facts.changedPaths else { return .run("can't tell what changed") }
        if changed.contains("backend/pyproject.toml") { return .run("backend/pyproject.toml changed") }
        return .skip("no package changes")
    }

    /// A changed path that goes into the built interface.
    static func isInterfaceSource(_ path: String) -> Bool {
        guard path.hasPrefix("frontend/") else { return false }
        if frontendExcludedPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        if frontendExcludedSuffixes.contains(where: { path.hasSuffix($0) }) { return false }
        return true
    }

    /// `git diff --name-only <old> HEAD` output, one path per line.
    static func changedPaths(fromDiff output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether the build at `distModified` predates the newest of `sources`.
    /// Nil dates — no build, nothing to compare — read as "not older": the
    /// missing-build rule covers that case on its own.
    static func isOlder(distModified: Date?, newestSource: Date?) -> Bool {
        guard let dist = distModified, let source = newestSource else { return false }
        return source > dist
    }
}
