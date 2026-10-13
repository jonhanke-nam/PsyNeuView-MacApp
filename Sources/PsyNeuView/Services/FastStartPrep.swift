import Foundation

/// The work a first server start would otherwise do, done during the
/// install instead (#223).
///
/// Measured in #215: after the packages are written, the first
/// `import psyneulink` compiles bytecode for 183 packages (about 4 s) and,
/// on a Mac that has never run matplotlib, builds its font cache (about
/// 8 s) — both inside the step the user watches as "Starting the server",
/// with nothing to look at. The install already shows progress, so the
/// same work is done there, as its own step so its time is its own.
///
/// Best effort throughout: a file that won't compile, or a matplotlib that
/// won't import, is logged and the first start does that work itself, as
/// it always did. Nothing here fails an install.
///
/// Only what is needed is done. A repair or an update whose install
/// changed nothing has its bytecode already; a Mac that built the font
/// cache for this matplotlib has it already. Both skipped, the step reads
/// "already prepared" rather than spending fifteen seconds redoing them.
///
/// `decide`, `compileTargets` and `commands` are pure; `run` executes.
enum FastStartPrep {

    /// One command for the environment's own Python.
    struct Command: Equatable, Sendable {
        /// A short, stable name for its timing: "compileBytecode".
        var id: String
        /// What the log says while it runs.
        var title: String
        /// The arguments to the interpreter.
        var arguments: [String]
    }

    // MARK: What is needed

    /// What the install and the Mac say.
    struct Facts: Equatable, Sendable {
        /// The install wrote or removed packages this run — uv reported
        /// installs, or pip reached "Installing collected packages"
        /// (`InstallTimeline.wrotePackages`).
        var packagesChanged: Bool
        /// A `fontlist-v*.json` exists in the config folder the server
        /// will use.
        var fontCachePresent: Bool
        /// matplotlib's installed version, from its dist-info; nil when it
        /// isn't installed or can't be read.
        var matplotlibVersion: String?
        /// The matplotlib version the font cache was last built for, from
        /// the stamp this app wrote; nil before the first build.
        var stampedVersion: String?
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
        var compileBytecode: Decision
        var fontCache: Decision

        /// Nothing to do: the step is skipped, with this reason.
        var skipsEverything: Bool { !compileBytecode.runs && !fontCache.runs }
        static let skipReason = "already prepared"
    }

    static func decide(_ facts: Facts) -> Plan {
        Plan(compileBytecode: compileBytecode(facts), fontCache: fontCache(facts))
    }

    /// Bytecode is a function of the packages: compile when they changed,
    /// not otherwise. (`compileall` is incremental besides — unchanged
    /// files are skipped by timestamp — so a run after a small change is
    /// short too.)
    static func compileBytecode(_ facts: Facts) -> Decision {
        facts.packagesChanged ? .run("packages were written") : .skip("packages unchanged")
    }

    /// The font cache is a function of the fonts and of matplotlib's
    /// version: build it when there is none, or when it was built for a
    /// different matplotlib (a cache for an older one is ignored by the
    /// newer, which rebuilds at the first start — the cost this step
    /// exists to move). A cache that exists but was never stamped — built
    /// by a start before this step existed, or by the user's own Python —
    /// gets the import once, which is quick when the cache is good, and
    /// is stamped after.
    static func fontCache(_ facts: Facts) -> Decision {
        guard facts.fontCachePresent else { return .run("no font cache yet") }
        guard let stamped = facts.stampedVersion else { return .run("font cache not yet checked") }
        guard let current = facts.matplotlibVersion else { return .run("can't tell matplotlib's version") }
        if stamped != current { return .run("matplotlib changed from \(stamped) to \(current)") }
        return .skip("font cache built for matplotlib \(current)")
    }

    /// The folder matplotlib keeps its font cache in, for the environment
    /// the server is launched with: `$MPLCONFIGDIR` when set, otherwise
    /// `~/.matplotlib` (matplotlib's own rule on a Mac).
    static func configDirectory(environment: [String: String]) -> URL? {
        if let dir = environment["MPLCONFIGDIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent(".matplotlib")
        }
        return nil
    }

    /// Whether a built font cache is in `directory`: matplotlib writes
    /// `fontlist-v<N>.json`.
    static func fontCachePresent(in directory: URL?) -> Bool {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return entries.contains { $0.hasPrefix("fontlist-v") && $0.hasSuffix(".json") }
    }

    /// Where the matplotlib version the font cache was built for is kept:
    /// with the app's data, next to the install.
    static func stampFile(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("matplotlib-font-cache.version")
    }

    static func stampedVersion(at file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// The folders whose Python files get compiled: the environment's
    /// site-packages, where PsyNeuLink and its dependencies live, plus a
    /// local PsyNeuLink checkout installed editable — its sources are
    /// outside site-packages, and it is the largest pure-Python tree of
    /// the lot.
    static func compileTargets(sitePackages: String?, pnlPipArgs: [String]) -> [String] {
        var targets: [String] = []
        if let sitePackages, !sitePackages.isEmpty { targets.append(sitePackages) }
        if case .local(let path)? = PsyNeuLinkInstall.kind(of: pnlPipArgs), !targets.contains(path) {
            targets.append(path)
        }
        return targets
    }

    /// The commands the plan calls for, in order: compile bytecode, then
    /// build the font cache.
    ///
    /// `compileall -q -j 0` uses every core and prints only what failed;
    /// a package carrying modules for another Python version makes it exit
    /// 1 after compiling everything else, which is normal. Importing
    /// `matplotlib.font_manager` is what builds the font cache — the
    /// module scans the system's fonts on import when the cache is missing
    /// or stale — so the import alone is the warm-up.
    static func commands(_ plan: Plan, compileTargets: [String]) -> [Command] {
        var out: [Command] = []
        if plan.compileBytecode.runs, !compileTargets.isEmpty {
            out.append(Command(
                id: "compileBytecode",
                title: "Compiling Python bytecode",
                arguments: ["-m", "compileall", "-q", "-j", "0"] + compileTargets))
        }
        if plan.fontCache.runs {
            out.append(Command(
                id: "fontCache",
                title: "Building matplotlib's font cache",
                arguments: ["-c", "import matplotlib.font_manager"]))
        }
        return out
    }

    /// Everything, for a first install.
    static let everything = Plan(
        compileBytecode: .run("first install"), fontCache: .run("first install"))

    /// `<venv>/lib/python3.X/site-packages`, when the environment has one.
    static func sitePackages(inVenv venv: URL) -> URL? {
        let fm = FileManager.default
        let lib = venv.appendingPathComponent("lib")
        guard let entries = try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)
        else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("python") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.appendingPathComponent("site-packages") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// Run the preparation against the environment under `repoPath`.
    ///
    /// The commands run with the environment the server is launched with
    /// (`ProcessManager.backendEnvironment`): the same `HOME`, so the font
    /// cache lands where matplotlib will look for it at the first start —
    /// `~/.matplotlib` on a Mac, or `$MPLCONFIGDIR` when the app was
    /// launched with one set, as the first-launch profile does.
    ///
    /// `packagesChanged` is what the install just said. Each command's time
    /// goes to `detail`, under the step the caller shows; what each said
    /// goes to `log`. Returns the plan, so the caller can mark the step
    /// skipped when nothing was needed.
    @MainActor
    @discardableResult
    static func run(
        repoPath: URL,
        pnlPipArgs: [String],
        packagesChanged: Bool,
        supportDirectory: URL = BundledPsyNeuView.supportDirectory(),
        log: @escaping (String) -> Void,
        detail: @escaping (InstallProgress.Detail) -> Void = { _ in }
    ) async -> Plan {
        let venv = repoPath.appendingPathComponent("backend/.venv")
        let python = venv.appendingPathComponent("bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            log("No Python in the environment — skipping the fast-start preparation.")
            return Plan(compileBytecode: .skip("no Python"), fontCache: .skip("no Python"))
        }
        let env = ProcessManager.backendEnvironment(base: Shell.userEnvironment(), repoPath: repoPath)
        let stamp = stampFile(supportDirectory: supportDirectory)
        let matplotlibVersion = VersionReport.installedVersion(of: "matplotlib", inVenv: venv)
        let plan = decide(Facts(
            packagesChanged: packagesChanged,
            fontCachePresent: fontCachePresent(in: configDirectory(environment: env)),
            matplotlibVersion: matplotlibVersion,
            stampedVersion: stampedVersion(at: stamp)))
        for (what, decision) in [("Bytecode", plan.compileBytecode), ("Font cache", plan.fontCache)]
        where !decision.runs {
            log("  \(what): \(decision.reason) — nothing to do.")
        }
        let targets = compileTargets(
            sitePackages: sitePackages(inVenv: venv)?.path, pnlPipArgs: pnlPipArgs)

        for command in commands(plan, compileTargets: targets) {
            log("\(command.title)...")
            let started = Date()
            let exitCode = await Shell.runStreaming(
                python.path,
                arguments: command.arguments,
                currentDirectory: repoPath.appendingPathComponent("backend"),
                environment: env,
                onOutput: { text in
                    Task { @MainActor in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { log("  " + trimmed) }
                    }
                })
            let seconds = Date().timeIntervalSince(started)
            detail(InstallProgress.Detail(
                id: command.id, title: command.title, seconds: seconds, bytes: nil))
            if exitCode == 0 {
                log(String(format: "  ✓ %@ in %.1f s", command.title.lowercased(), seconds))
                if command.id == "fontCache", let matplotlibVersion {
                    // Remember which matplotlib the cache is for, so the next
                    // install on this Mac skips the build.
                    try? FileManager.default.createDirectory(
                        at: supportDirectory, withIntermediateDirectories: true)
                    try? (matplotlibVersion + "\n").write(to: stamp, atomically: true, encoding: .utf8)
                }
            } else {
                log(String(format: "  %@ ended with exit code %d after %.1f s — not a problem; "
                           + "the first start does what is left.", command.title, exitCode, seconds))
            }
        }
        return plan
    }
}
