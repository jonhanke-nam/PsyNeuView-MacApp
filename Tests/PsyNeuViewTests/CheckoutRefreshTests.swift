import XCTest
@testable import PsyNeuView

/// Which refresh steps a checkout start runs, from what the pull changed
/// (#232). A docs commit used to rebuild the interface.
final class CheckoutRefreshTests: XCTestCase {

    private func facts(
        pulled: Bool = true,
        changed: [String]? = [],
        nodeModules: Bool = true,
        dist: Bool = true,
        stale: Bool = false
    ) -> CheckoutRefresh.Facts {
        .init(pulled: pulled, changedPaths: changed, nodeModulesPresent: nodeModules,
              distPresent: dist, distOlderThanSources: stale)
    }

    func testNothingPulledSkipsEverythingWithAReason() {
        let plan = CheckoutRefresh.decide(facts(pulled: false))
        XCTAssertEqual(plan.nodePackages, .skip("nothing new to check"))
        XCTAssertEqual(plan.rebuildFrontend, .skip("nothing new to build"))
        XCTAssertEqual(plan.pythonPackages, .skip("no package changes"))
        XCTAssertFalse(plan.nodePackages.runs)
    }

    func testADocsCommitRebuildsNothing() {
        let plan = CheckoutRefresh.decide(facts(changed: ["README.md", "docs/guide.md", "frontend/README.md"]))
        XCTAssertEqual(plan.nodePackages, .skip("no package changes"))
        XCTAssertEqual(plan.rebuildFrontend, .skip("no interface changes"))
        XCTAssertEqual(plan.pythonPackages, .skip("no package changes"))
    }

    func testAnInterfaceSourceChangeRebuildsButDoesNotReinstall() {
        let plan = CheckoutRefresh.decide(facts(changed: ["frontend/src/App.tsx"]))
        XCTAssertEqual(plan.nodePackages, .skip("no package changes"))
        XCTAssertEqual(plan.rebuildFrontend, .run("interface changed"))
        XCTAssertEqual(plan.pythonPackages, .skip("no package changes"))
    }

    func testAPackageListChangeRunsNpmInstall() {
        XCTAssertEqual(CheckoutRefresh.decide(facts(changed: ["frontend/package-lock.json"])).nodePackages,
                       .run("package list changed"))
        XCTAssertEqual(CheckoutRefresh.decide(facts(changed: ["frontend/package.json"])).nodePackages,
                       .run("package list changed"))
        // A package.json elsewhere isn't the interface's.
        XCTAssertFalse(CheckoutRefresh.decide(facts(changed: ["package.json"])).nodePackages.runs)
    }

    func testEndToEndTestsAndSpecsAreNotInterfaceSources() {
        let plan = CheckoutRefresh.decide(facts(changed: [
            "frontend/e2e/smoke.spec.ts", "frontend/src/lib/x.test.ts", "frontend/tests/a.ts",
        ]))
        XCTAssertEqual(plan.rebuildFrontend, .skip("no interface changes"))
        XCTAssertTrue(CheckoutRefresh.isInterfaceSource("frontend/src/main.tsx"))
        XCTAssertTrue(CheckoutRefresh.isInterfaceSource("frontend/index.html"))
        XCTAssertTrue(CheckoutRefresh.isInterfaceSource("frontend/vite.config.ts"))
        XCTAssertFalse(CheckoutRefresh.isInterfaceSource("backend/app/main.py"))
    }

    func testBackendProjectFileChangeRunsPythonPackages() {
        let plan = CheckoutRefresh.decide(facts(changed: ["backend/pyproject.toml", "backend/app/main.py"]))
        XCTAssertEqual(plan.pythonPackages, .run("backend/pyproject.toml changed"))
        XCTAssertFalse(CheckoutRefresh.decide(facts(changed: ["backend/app/main.py"])).pythonPackages.runs)
    }

    func testMissingBuildOrPackagesRunRegardlessOfThePull() {
        let offline = CheckoutRefresh.decide(facts(pulled: false, nodeModules: false, dist: false))
        XCTAssertEqual(offline.nodePackages, .run("no packages installed yet"))
        XCTAssertEqual(offline.rebuildFrontend, .run("no built interface yet"))
        XCTAssertEqual(offline.pythonPackages, .skip("no package changes"))
    }

    func testABuildOlderThanTheSourcesIsRebuilt() {
        let plan = CheckoutRefresh.decide(facts(pulled: false, stale: true))
        XCTAssertEqual(plan.rebuildFrontend, .run("sources newer than the build"))
        XCTAssertFalse(plan.nodePackages.runs)
    }

    func testNotKnowingWhatChangedRunsEverything() {
        let plan = CheckoutRefresh.decide(facts(changed: nil))
        XCTAssertTrue(plan.nodePackages.runs)
        XCTAssertTrue(plan.rebuildFrontend.runs)
        XCTAssertTrue(plan.pythonPackages.runs)
    }

    func testChangedPathsReadFromGitDiff() {
        XCTAssertEqual(CheckoutRefresh.changedPaths(fromDiff: "a/b.py\n\nfrontend/src/x.ts \n"),
                       ["a/b.py", "frontend/src/x.ts"])
        XCTAssertEqual(CheckoutRefresh.changedPaths(fromDiff: ""), [])
    }

    func testOlderOnlyWhenBothDatesAreKnown() {
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(CheckoutRefresh.isOlder(distModified: t, newestSource: t.addingTimeInterval(1)))
        XCTAssertFalse(CheckoutRefresh.isOlder(distModified: t, newestSource: t))
        XCTAssertFalse(CheckoutRefresh.isOlder(distModified: nil, newestSource: t))
        XCTAssertFalse(CheckoutRefresh.isOlder(distModified: t, newestSource: nil))
    }

    // MARK: The pull step's own reasons

    func testThePullStepSaysInAFewWordsWhyItDidNothing() {
        func state(branch: String? = "devel", fetched: Bool = true, changed: Int = 0,
                   ahead: Int = 0, behind: Int = 0) -> CheckoutPull.State {
            .init(branch: branch, fetched: fetched, changedFiles: changed, ahead: ahead, behind: behind)
        }
        XCTAssertEqual(Updater.pullSkipReason(for: state()), "already up to date")
        XCTAssertEqual(Updater.pullSkipReason(for: state(branch: nil)), "not on a branch")
        XCTAssertEqual(Updater.pullSkipReason(for: state(fetched: false)), "couldn't reach origin")
        XCTAssertEqual(Updater.pullSkipReason(for: state(changed: 2)), "local changes; not pulled")
        XCTAssertEqual(Updater.pullSkipReason(for: state(ahead: 1, behind: 1)), "diverged from origin; not pulled")
        XCTAssertEqual(Updater.pullSkipReason(for: state(ahead: 1)), "ahead of origin")
    }
}
