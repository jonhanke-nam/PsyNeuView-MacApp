import XCTest
@testable import PsyNeuView

/// The checklist follows each install path's steps as they change (#196).
@MainActor
final class InstallProgressTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testTheBundledSetupFollowsTheInstaller() {
        var recorded: [ProgressStep: Double] = [:]
        let progress = InstallProgress(
            steps: ProgressPlan.steps(for: .bundledSetup), startedAt: t0,
            record: { recorded[$0] = $1 })

        // What Installer.installAll reports on the bundled path, in order.
        progress.apply(.xcodeTools, .completed, at: at(0))   // not shown on this path
        progress.apply(.githubAuth, .completed, at: at(0))
        progress.apply(.python, .running, at: at(0))
        progress.apply(.python, .completed, at: at(5))
        progress.apply(.node, .completed, at: at(5))
        progress.apply(.cloneRepo, .running, at: at(5))
        progress.apply(.cloneRepo, .completed, at: at(8))
        progress.apply(.createVenv, .running, at: at(8))
        XCTAssertEqual(progress.currentStep, .createEnvironment)
        progress.apply(.createVenv, .completed, at: at(12))
        progress.apply(.installPythonDeps, .running, at: at(12))

        XCTAssertEqual(progress.states(at: at(72)).map(\.status), [
            .done(seconds: 5), .done(seconds: 3), .done(seconds: 4), .running(elapsed: 60), .pending,
        ])
        XCTAssertEqual(recorded[.python], 5)
        XCTAssertNil(recorded[.installPackages])

        progress.apply(.installPythonDeps, .completed, at: at(300))
        XCTAssertEqual(recorded[.installPackages], 288)
        // The first start's one-time work follows the packages (#223).
        progress.apply(.prepareFastStart, .running, at: at(300))
        XCTAssertEqual(progress.currentStep, .prepareFastStart)
        progress.apply(.prepareFastStart, .completed, at: at(304))
        XCTAssertNil(progress.currentStep)
        XCTAssertEqual(progress.estimate(at: at(304)).remaining, 0...0)
        XCTAssertEqual(recorded[.prepareFastStart], 4)
    }

    func testACheckoutSetupShowsTheCloneOnlySteps() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .checkoutSetup), startedAt: t0)
        progress.apply(.node, .running, at: at(1))
        XCTAssertEqual(progress.currentStep, .node)
        progress.apply(.buildFrontend, .failed("vite not found"), at: at(2))
        XCTAssertTrue(progress.hasFailed)
        XCTAssertEqual(progress.statuses[.buildFrontend], .failed("vite not found"))
    }

    func testCloningPsyNeuLinkComesFirst() {
        let progress = InstallProgress(
            steps: ProgressPlan.steps(for: .bundledSetup, clonesPsyNeuLink: true), startedAt: t0)
        progress.begin(.clonePsyNeuLink, at: at(0))
        progress.finish(.clonePsyNeuLink, at: at(40))
        XCTAssertEqual(progress.statuses[.clonePsyNeuLink], .done(seconds: 40))
    }

    func testAnUpdateWithAnEnvironmentAlreadyBuiltSkipsToStarting() {
        // #186 / #195: the included version unpacked, its environment usable.
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .update), startedAt: t0)
        progress.begin(.getPsyNeuView, at: at(0))
        progress.finish(.getPsyNeuView, at: at(6))
        progress.begin(.startServer, at: at(6))
        XCTAssertEqual(progress.states(at: at(10)).map(\.status), [
            .done(seconds: 6), .skipped(reason: nil), .skipped(reason: nil), .skipped(reason: nil),
            .skipped(reason: nil), .running(elapsed: 4), .pending, .pending,
        ])
    }

    func testAPlainStartFailsVisibly() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .start), startedAt: t0)
        progress.begin(.startServer, at: at(0))
        progress.failCurrent(reason: "server stopped")
        XCTAssertTrue(progress.hasFailed)
        XCTAssertNil(progress.currentStep)
    }

    func testFinishingAStepThatNeverRanIsASkipNotATiming() {
        var recorded: [ProgressStep] = []
        let progress = InstallProgress(
            steps: [.python, .startServer], startedAt: t0, record: { step, _ in recorded.append(step) })
        progress.finish(.python, at: at(3))
        XCTAssertEqual(progress.statuses[.python], .skipped(reason: nil))
        XCTAssertEqual(recorded, [])
    }

    func testTheInstallerReportsEachChange() {
        let installer = Installer()
        var seen: [InstallStep] = []
        installer.onStepChange = { step, _ in seen.append(step) }
        installer.stepStatuses[.python] = .running
        installer.stepStatuses[.python] = .running   // no change, no report
        installer.stepStatuses[.python] = .completed
        XCTAssertEqual(seen, [.python, .python])
    }

    /// Report a Problem (#202) carries the checklist in words.
    func testTheChecklistReadsInAReport() {
        let progress = InstallProgress(
            steps: [.python, .installPackages, .startServer, .buildFrontend], startedAt: t0)
        progress.begin(.installPackages, at: at(0))
        progress.finish(.installPackages, at: at(12.34))
        progress.begin(.startServer, at: at(13))
        XCTAssertEqual(progress.reportSteps(at: at(20)).map(\.status),
                       ["not needed", "done in 12.3 s", "running for 7.0 s", "not reached"])
        progress.skip(.buildFrontend, reason: "no interface changes")
        XCTAssertEqual(progress.reportSteps(at: at(20))[3].status, "not needed (no interface changes)")
        progress.failCurrent(reason: "server stopped")
        XCTAssertEqual(progress.reportSteps(at: at(20))[2],
                       ProblemReport.Step(title: ProgressStep.startServer.title, status: "failed: server stopped"))
    }

    /// The parts of a step follow it in the report (#215), so "install took
    /// 240 s" says which 240 s — and a user's real timings reach us.
    func testTimedPartsOfAStepFollowItInTheReport() {
        let progress = InstallProgress(steps: [.installPackages, .startServer], startedAt: t0)
        progress.begin(.installPackages, at: at(0))
        progress.note(.init(id: "psyneulink/resolveAndDownload",
                            title: "PsyNeuLink (git+…@devel) with pip: resolve dependencies and download wheels",
                            seconds: 95.04, bytes: 310_200_000), under: .installPackages)
        progress.note(.init(id: "psyneulink/total", title: "PsyNeuLink (git+…@devel) with pip: total",
                            seconds: 240.1, bytes: 310_200_000), under: .installPackages)
        progress.finish(.installPackages, at: at(240.1))
        // A part noted under a step this path doesn't show is dropped, like
        // the installer's own changes are.
        progress.note(.init(id: "x", title: "x", seconds: 1, bytes: nil), under: .buildFrontend)

        let report = progress.reportSteps(at: at(241))
        XCTAssertEqual(report.map(\.title), [
            ProgressStep.installPackages.title,
            "    PsyNeuLink (git+…@devel) with pip: resolve dependencies and download wheels",
            "    PsyNeuLink (git+…@devel) with pip: total",
            ProgressStep.startServer.title,
        ])
        XCTAssertEqual(report[1].status, "95.0 s, 310.2 MB downloaded")
        XCTAssertEqual(report[2].status, "240.1 s, 310.2 MB downloaded")
    }

    /// The boot report carries the same steps with stable ids, a running step
    /// counted up to now — it is written the moment the server answers, with
    /// "Start the server" still in progress.
    func testBootTimingsHaveStableIdsAndCountARunningStep() {
        let progress = InstallProgress(steps: [.getPsyNeuView, .installPackages, .startServer], startedAt: t0)
        progress.begin(.getPsyNeuView, at: at(0))
        progress.finish(.getPsyNeuView, at: at(6))
        progress.begin(.installPackages, at: at(6))
        progress.note(.init(id: "backend/resolve", title: "Backend packages with uv: resolve dependencies",
                            seconds: 1.2, bytes: nil), under: .installPackages)
        progress.finish(.installPackages, at: at(66))
        progress.begin(.startServer, at: at(66))
        progress.note(.init(id: "health", title: "Server answered /health", seconds: 30, bytes: nil),
                      under: .startServer)

        let timings = progress.bootTimings(at: at(100))
        XCTAssertEqual(timings.map(\.id), [
            "getPsyNeuView", "installPackages", "installPackages/backend/resolve",
            "startServer", "startServer/health",
        ])
        XCTAssertEqual(timings.map(\.seconds), [6, 60, 1.2, 34, 30])
    }

    // MARK: A checkout start (#232)

    func testACheckoutStartSkipsWithReasonsAndRunsWhatItMust() {
        var recorded: [ProgressStep: Double] = [:]
        let progress = InstallProgress(
            steps: ProgressPlan.steps(for: .checkoutStart), startedAt: t0,
            record: { recorded[$0] = $1 })
        progress.begin(.pullCheckout, at: at(0))
        progress.skip(.pullCheckout, reason: "already up to date")
        progress.skip(.checkNodePackages, reason: "nothing new to check")
        progress.begin(.rebuildFrontend, at: at(1))
        progress.finish(.rebuildFrontend, at: at(9))
        progress.skip(.updatePythonPackages, reason: "no package changes")
        progress.begin(.startServer, at: at(9))

        XCTAssertEqual(progress.states(at: at(12)).map(\.status), [
            .skipped(reason: "already up to date"),
            .skipped(reason: "nothing new to check"),
            .done(seconds: 8),
            .skipped(reason: "no package changes"),
            .running(elapsed: 3), .pending, .pending,
        ])
        // A check that found nothing to do isn't recorded as a run of the step.
        XCTAssertNil(recorded[.pullCheckout])
        XCTAssertEqual(recorded[.rebuildFrontend], 8)
    }

    func testASkipIsFinalAndADoneStepCannotBeSkipped() {
        let progress = InstallProgress(steps: [.pullCheckout, .startServer], startedAt: t0)
        progress.skip(.pullCheckout, reason: "offline")
        progress.finish(.pullCheckout, at: at(1))
        XCTAssertEqual(progress.statuses[.pullCheckout], .skipped(reason: "offline"))
        progress.begin(.startServer, at: at(1))
        progress.finish(.startServer, at: at(4))
        progress.skip(.startServer, reason: "late")
        XCTAssertEqual(progress.statuses[.startServer], .done(seconds: 3))
    }

    func testInsertingAStepPlacesItAfterItsAnchorOnce() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .start), startedAt: t0)
        progress.insert(.installPsyNeuLinkUpdate, after: .startServer)
        progress.insert(.installPsyNeuLinkUpdate, after: .startServer)
        XCTAssertEqual(progress.steps, [.startServer, .installPsyNeuLinkUpdate, .loadPsyNeuLink, .warmModelRunner])
        XCTAssertTrue(progress.isPending(.installPsyNeuLinkUpdate))
    }

    func testUsualComesFromThisMacsHistory() {
        let progress = InstallProgress(
            steps: [.loadPsyNeuLink], startedAt: t0, history: [.loadPsyNeuLink: [30, 4, 5]])
        XCTAssertEqual(progress.usual(.loadPsyNeuLink), 5)
        XCTAssertNil(InstallProgress(steps: [.loadPsyNeuLink], startedAt: t0).usual(.loadPsyNeuLink))
    }
}
