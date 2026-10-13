import XCTest
@testable import PsyNeuView

// Compiling bytecode and building the font cache during the install (#223).
// XCTest (not Swift Testing) so it runs on the CI toolchain's Xcode.

final class FastStartPrepTests: XCTestCase {
    let sitePackages = "/tree/backend/.venv/lib/python3.14/site-packages"
    let devel = ["git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"]

    // MARK: What gets compiled

    func testSitePackagesIsCompiledForAGitHubOrPyPIInstall() {
        XCTAssertEqual(
            FastStartPrep.compileTargets(sitePackages: sitePackages, pnlPipArgs: devel),
            [sitePackages])
        XCTAssertEqual(
            FastStartPrep.compileTargets(sitePackages: sitePackages, pnlPipArgs: ["psyneulink"]),
            [sitePackages])
    }

    func testALocalCheckoutIsCompiledToo() {
        // Its sources live outside site-packages, and it is the largest
        // pure-Python tree of the lot.
        XCTAssertEqual(
            FastStartPrep.compileTargets(
                sitePackages: sitePackages, pnlPipArgs: ["-e", "/Users/someone/PsyNeuLink"]),
            [sitePackages, "/Users/someone/PsyNeuLink"])
    }

    func testNoSitePackagesMeansNothingButTheCheckout() {
        XCTAssertEqual(FastStartPrep.compileTargets(sitePackages: nil, pnlPipArgs: devel), [])
        XCTAssertEqual(
            FastStartPrep.compileTargets(sitePackages: "", pnlPipArgs: ["-e", "/Users/someone/PsyNeuLink"]),
            ["/Users/someone/PsyNeuLink"])
    }

    // MARK: What is needed

    private func facts(
        packagesChanged: Bool = true, fontCachePresent: Bool = false,
        matplotlibVersion: String? = "3.11.2", stampedVersion: String? = nil
    ) -> FastStartPrep.Facts {
        FastStartPrep.Facts(
            packagesChanged: packagesChanged, fontCachePresent: fontCachePresent,
            matplotlibVersion: matplotlibVersion, stampedVersion: stampedVersion)
    }

    func testAFirstInstallDoesEverything() {
        let plan = FastStartPrep.decide(facts())
        XCTAssertEqual(plan.compileBytecode, .run("packages were written"))
        XCTAssertEqual(plan.fontCache, .run("no font cache yet"))
        XCTAssertFalse(plan.skipsEverything)
    }

    func testARepairThatChangedNothingOnAPreparedMacSkipsBoth() {
        // uv audited the environment and wrote nothing; the font cache was
        // built for this very matplotlib.
        let plan = FastStartPrep.decide(facts(
            packagesChanged: false, fontCachePresent: true, stampedVersion: "3.11.2"))
        XCTAssertEqual(plan.compileBytecode, .skip("packages unchanged"))
        XCTAssertEqual(plan.fontCache, .skip("font cache built for matplotlib 3.11.2"))
        XCTAssertTrue(plan.skipsEverything)
        XCTAssertEqual(FastStartPrep.Plan.skipReason, "already prepared")
    }

    func testBytecodeFollowsThePackages() {
        XCTAssertTrue(FastStartPrep.compileBytecode(facts(packagesChanged: true)).runs)
        XCTAssertFalse(FastStartPrep.compileBytecode(facts(packagesChanged: false)).runs)
    }

    func testTheFontCacheIsRebuiltWhenMatplotlibMoved() {
        let plan = FastStartPrep.decide(facts(
            packagesChanged: true, fontCachePresent: true, matplotlibVersion: "3.12.0", stampedVersion: "3.11.2"))
        XCTAssertEqual(plan.fontCache, .run("matplotlib changed from 3.11.2 to 3.12.0"))
    }

    func testACacheThisAppNeverStampedGetsTheImportOnce() {
        // Built by a start before this step existed, or by the user's own
        // Python: the import is quick when the cache is good, and stamps it.
        let plan = FastStartPrep.decide(facts(packagesChanged: false, fontCachePresent: true, stampedVersion: nil))
        XCTAssertEqual(plan.fontCache, .run("font cache not yet checked"))
        XCTAssertFalse(plan.skipsEverything)
    }

    func testAnUnreadableMatplotlibVersionRebuildsRatherThanGuesses() {
        let plan = FastStartPrep.decide(facts(
            packagesChanged: false, fontCachePresent: true, matplotlibVersion: nil, stampedVersion: "3.11.2"))
        XCTAssertEqual(plan.fontCache, .run("can't tell matplotlib's version"))
    }

    func testNoCacheMeansABuildWhateverTheStampSays() {
        let plan = FastStartPrep.decide(facts(fontCachePresent: false, stampedVersion: "3.11.2"))
        XCTAssertEqual(plan.fontCache, .run("no font cache yet"))
    }

    // MARK: Where the font cache is

    func testTheConfigFolderIsMPLCONFIGDIROrDotMatplotlibInHome() {
        XCTAssertEqual(
            FastStartPrep.configDirectory(environment: ["HOME": "/Users/someone"])?.path,
            "/Users/someone/.matplotlib")
        XCTAssertEqual(
            FastStartPrep.configDirectory(environment: ["HOME": "/Users/someone", "MPLCONFIGDIR": "/tmp/mpl"])?.path,
            "/tmp/mpl")
        XCTAssertEqual(
            FastStartPrep.configDirectory(environment: ["HOME": "/Users/someone", "MPLCONFIGDIR": ""])?.path,
            "/Users/someone/.matplotlib")
        XCTAssertNil(FastStartPrep.configDirectory(environment: [:]))
    }

    func testAFontCacheIsAFontlistJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FastStartPrep.fontCachePresent(in: dir))
        XCTAssertFalse(FastStartPrep.fontCachePresent(in: nil))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("matplotlibrc"), atomically: true, encoding: .utf8)
        XCTAssertFalse(FastStartPrep.fontCachePresent(in: dir))
        try "{}".write(to: dir.appendingPathComponent("fontlist-v3.11.0.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(FastStartPrep.fontCachePresent(in: dir))
    }

    func testTheStampLivesWithTheAppsDataAndReadsBack() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let stamp = FastStartPrep.stampFile(supportDirectory: support)
        XCTAssertEqual(stamp.lastPathComponent, "matplotlib-font-cache.version")
        XCTAssertNil(FastStartPrep.stampedVersion(at: stamp))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "3.11.2\n".write(to: stamp, atomically: true, encoding: .utf8)
        XCTAssertEqual(FastStartPrep.stampedVersion(at: stamp), "3.11.2")
        try "\n".write(to: stamp, atomically: true, encoding: .utf8)
        XCTAssertNil(FastStartPrep.stampedVersion(at: stamp))
    }

    // MARK: The commands

    func testBytecodeIsCompiledOnEveryCoreQuietlyThenTheFontCacheIsBuilt() {
        let commands = FastStartPrep.commands(FastStartPrep.everything, compileTargets: [sitePackages])
        XCTAssertEqual(commands.map(\.id), ["compileBytecode", "fontCache"])
        XCTAssertEqual(commands[0].arguments, ["-m", "compileall", "-q", "-j", "0", sitePackages])
        XCTAssertEqual(commands[1].arguments, ["-c", "import matplotlib.font_manager"])
        for command in commands {
            XCTAssertFalse(command.title.isEmpty)
        }
    }

    func testEveryCompileTargetIsOneRun() {
        let commands = FastStartPrep.commands(
            FastStartPrep.everything, compileTargets: [sitePackages, "/Users/someone/PsyNeuLink"])
        XCTAssertEqual(Array(commands[0].arguments.suffix(2)), [sitePackages, "/Users/someone/PsyNeuLink"])
    }

    func testWithNothingToCompileOnlyTheFontCacheIsBuilt() {
        let commands = FastStartPrep.commands(FastStartPrep.everything, compileTargets: [])
        XCTAssertEqual(commands.map(\.id), ["fontCache"])
    }

    func testOnlyWhatThePlanCallsForRuns() {
        let fontOnly = FastStartPrep.Plan(compileBytecode: .skip("packages unchanged"), fontCache: .run("no font cache yet"))
        XCTAssertEqual(FastStartPrep.commands(fontOnly, compileTargets: [sitePackages]).map(\.id), ["fontCache"])
        let bytecodeOnly = FastStartPrep.Plan(compileBytecode: .run("packages were written"), fontCache: .skip("built"))
        XCTAssertEqual(FastStartPrep.commands(bytecodeOnly, compileTargets: [sitePackages]).map(\.id), ["compileBytecode"])
        let nothing = FastStartPrep.Plan(compileBytecode: .skip("packages unchanged"), fontCache: .skip("built"))
        XCTAssertEqual(FastStartPrep.commands(nothing, compileTargets: [sitePackages]), [])
    }

    // MARK: Finding site-packages

    func testSitePackagesIsFoundUnderTheEnvironmentsLib() throws {
        let venv = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: venv) }
        XCTAssertNil(FastStartPrep.sitePackages(inVenv: venv))

        let site = venv.appendingPathComponent("lib/python3.14/site-packages")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        // /var is a link to /private/var: compare the folders, not the spellings.
        XCTAssertEqual(FastStartPrep.sitePackages(inVenv: venv)?.resolvingSymlinksInPath().path,
                       site.resolvingSymlinksInPath().path)
    }

    func testAnEnvironmentWithoutSitePackagesHasNone() throws {
        let venv = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: venv) }
        try FileManager.default.createDirectory(
            at: venv.appendingPathComponent("lib/python3.14"), withIntermediateDirectories: true)
        XCTAssertNil(FastStartPrep.sitePackages(inVenv: venv))
    }

    // MARK: On the checklist

    func testTheStepFollowsThePackageInstallOnEveryPathThatWritesPackages() {
        for path in [ProgressPlan.Path.bundledSetup, .checkoutSetup, .update, .repair] {
            let steps = ProgressPlan.steps(for: path)
            guard let install = steps.firstIndex(of: .installPackages) else {
                XCTFail("\(path) has no package install")
                continue
            }
            XCTAssertEqual(steps[install + 1], .prepareFastStart, "\(path)")
        }
        // A start that installs nothing has no such step; a checkout start
        // adds it only when its package step installed something.
        XCTAssertFalse(ProgressPlan.steps(for: .start).contains(.prepareFastStart))
        XCTAssertFalse(ProgressPlan.steps(for: .checkoutStart).contains(.prepareFastStart))
    }

    func testTheInstallerStepMapsToTheChecklistStep() {
        XCTAssertEqual(ProgressStep(InstallStep.prepareFastStart), .prepareFastStart)
        XCTAssertEqual(ProgressStep.prepareFastStart.title, "Preparing Python for a fast first start")
    }

    @MainActor
    func testAStepTheInstallerSkippedReadsAlreadyPrepared() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .repair), startedAt: Date())
        progress.apply(.installPythonDeps, .running)
        progress.apply(.installPythonDeps, .completed)
        progress.apply(.prepareFastStart, .running)
        progress.apply(.prepareFastStart, .skipped("already prepared"))
        XCTAssertEqual(progress.statuses[.prepareFastStart], .skipped(reason: "already prepared"))
        // The repair checklist: Python, environment, packages, then this step.
        XCTAssertEqual(progress.reportSteps()[3].title, ProgressStep.prepareFastStart.title)
        XCTAssertEqual(progress.reportSteps()[3].status, "not needed (already prepared)")
    }

    // MARK: Whether the install wrote packages

    func testUvInstallingPackagesCountsAsWriting() {
        var t = InstallTimeline(label: "x", id: "x", startedAt: Date())
        t.observe("Resolved 183 packages in 11.2s", at: Date())
        XCTAssertFalse(t.wrotePackages)
        t.observe("Installed 183 packages in 812ms", at: Date())
        XCTAssertTrue(t.wrotePackages)
    }

    func testUvAuditingOrInstallingNothingDoesNotCount() {
        var t = InstallTimeline(label: "x", id: "x", startedAt: Date())
        t.observe("Audited 183 packages in 2ms", at: Date())
        t.observe("Installed 0 packages in 1ms", at: Date())
        XCTAssertFalse(t.wrotePackages)
        t.observe("Uninstalled 1 package in 16ms", at: Date())
        XCTAssertTrue(t.wrotePackages)
    }

    func testPipInstallingCollectedPackagesCountsAsWriting() {
        var t = InstallTimeline(label: "x", id: "x", startedAt: Date())
        t.observe("Requirement already satisfied: numpy in ./.venv/lib/python3.14/site-packages", at: Date())
        XCTAssertFalse(t.wrotePackages)
        t.observe("Installing collected packages: psyneulink", at: Date())
        XCTAssertTrue(t.wrotePackages)
    }
}
