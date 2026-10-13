import XCTest
@testable import PsyNeuView

/// Time remaining for an install or start, as a range (#196).
final class ProgressEstimateTests: XCTestCase {

    private typealias State = ProgressEstimate.StepState

    func testNoHistoryUsesTypicalTimes() {
        let estimate = ProgressEstimate.estimate([
            State(step: .createEnvironment, status: .pending),
            State(step: .installPackages, status: .pending),
        ])
        XCTAssertEqual(estimate.remaining.lowerBound, 3 + 120)
        XCTAssertEqual(estimate.remaining.upperBound, 20 + 480)
        XCTAssertFalse(estimate.overrunning)
        XCTAssertNil(estimate.currentFraction)
    }

    func testFinishedAndSkippedStepsCountForNothing() {
        let estimate = ProgressEstimate.estimate([
            State(step: .python, status: .done(seconds: 42)),
            State(step: .getPsyNeuView, status: .skipped(reason: "already unpacked")),
            State(step: .startServer, status: .pending),
        ])
        XCTAssertEqual(estimate.remaining, ProgressStep.startServer.typical)
    }

    func testAllDoneIsNothingLeft() {
        let estimate = ProgressEstimate.estimate([
            State(step: .startServer, status: .done(seconds: 30)),
        ])
        XCTAssertEqual(estimate.remaining, 0...0)
        XCTAssertEqual(ProgressEstimate.phrase(estimate), "Less than a minute left")
    }

    func testTheStepInProgressCountsOnlyWhatIsLeftOfIt() {
        let estimate = ProgressEstimate.estimate([
            State(step: .installPackages, status: .running(elapsed: 100)),
        ])
        XCTAssertEqual(estimate.remaining.lowerBound, 20)
        XCTAssertEqual(estimate.remaining.upperBound, 380)
        XCTAssertFalse(estimate.overrunning)
        XCTAssertEqual(estimate.currentFraction ?? -1, 100.0 / 300.0, accuracy: 0.0001)
    }

    func testAStepOverItsEstimateIsOverrunningNotNegative() {
        // Past the server step's 30 s upper bound, short of the 3x stall line.
        let estimate = ProgressEstimate.estimate([
            State(step: .startServer, status: .running(elapsed: 60)),
        ])
        XCTAssertEqual(estimate.remaining, 0...0)
        XCTAssertTrue(estimate.overrunning)
        XCTAssertFalse(estimate.stalled)
        // The bar never claims to be finished while the step is still running.
        XCTAssertEqual(estimate.currentFraction, 0.95)
        XCTAssertEqual(ProgressEstimate.phrase(estimate), "Taking longer than usual")
    }

    func testAnOverrunStillCountsTheStepsAfterIt() {
        let estimate = ProgressEstimate.estimate([
            State(step: .installPackages, status: .running(elapsed: 600)),
            State(step: .startServer, status: .pending),
        ])
        XCTAssertTrue(estimate.overrunning)
        XCTAssertEqual(estimate.remaining, ProgressStep.startServer.typical)
    }

    func testFarOverItsEstimateIsStalled() {
        let estimate = ProgressEstimate.estimate([
            State(step: .startServer, status: .running(elapsed: 91 * 3)),
        ])
        XCTAssertTrue(estimate.stalled)
    }

    func testThisMacsHistoryReplacesTheTypicalTime() {
        // This Mac installs packages in about 4 minutes.
        let history: [ProgressStep: [Double]] = [.installPackages: [230, 250, 240]]
        let estimate = ProgressEstimate.estimate(
            [State(step: .installPackages, status: .pending)], history: history)
        XCTAssertEqual(estimate.remaining.lowerBound, 180)
        XCTAssertEqual(estimate.remaining.upperBound, 360)
    }

    func testOnlyTheMostRecentRunsCount() {
        let range = ProgressEstimate.expected(.python, history: [500, 500, 10, 10, 10, 10, 10])
        XCTAssertEqual(range.lowerBound, 7.5)
    }

    func testAVeryShortHistoryStillGivesARange() {
        let range = ProgressEstimate.expected(.startServer, history: [2])
        XCTAssertLessThan(range.lowerBound, range.upperBound)
    }

    func testPhrasesAreRangesNotCountdowns() {
        func phrase(_ low: Double, _ high: Double) -> String {
            ProgressEstimate.phrase(.init(
                remaining: low...high, overrunning: false, stalled: false, currentFraction: nil))
        }
        XCTAssertEqual(phrase(10, 50), "Less than a minute left")
        XCTAssertEqual(phrase(50, 70), "About 1–2 minutes left")
        XCTAssertEqual(phrase(150, 500), "About 3–9 minutes left")
        XCTAssertEqual(phrase(60, 60), "About a minute left")
        XCTAssertEqual(phrase(240, 240), "About 4 minutes left")
    }

    func testClock() {
        XCTAssertEqual(ProgressEstimate.clock(42), "0:42")
        XCTAssertEqual(ProgressEstimate.clock(75.9), "1:15")
        XCTAssertEqual(ProgressEstimate.clock(3723), "1:02:03")
        XCTAssertEqual(ProgressEstimate.clock(-3), "0:00")
    }

    // MARK: Plans

    func testEachPathListsOnlyItsOwnSteps() {
        XCTAssertEqual(ProgressPlan.steps(for: .bundledSetup),
                       [.python, .getPsyNeuView, .createEnvironment, .installPackages, .prepareFastStart])
        XCTAssertFalse(ProgressPlan.steps(for: .bundledSetup).contains(.node))
        XCTAssertTrue(ProgressPlan.steps(for: .checkoutSetup).contains(.buildFrontend))
        XCTAssertEqual(ProgressPlan.steps(for: .update).first, .getPsyNeuView)
        XCTAssertEqual(ProgressPlan.steps(for: .update).last, .warmModelRunner)
        XCTAssertEqual(ProgressPlan.steps(for: .start), [.startServer, .loadPsyNeuLink, .warmModelRunner])
        XCTAssertEqual(ProgressPlan.steps(for: .bundledSetup, clonesPsyNeuLink: true).first,
                       .clonePsyNeuLink)
        XCTAssertEqual(Array(ProgressPlan.steps(for: .bundledSetup, thenStart: true).suffix(3)),
                       [.startServer, .loadPsyNeuLink, .warmModelRunner])
        XCTAssertEqual(ProgressPlan.steps(for: .repair, thenStart: true).filter { $0 == .startServer }.count, 1)
    }

    /// Every start shows the same server steps; a checkout start lists what
    /// its pull may make necessary first (#232).
    func testACheckoutStartListsItsRefreshStepsThenTheServer() {
        XCTAssertEqual(ProgressPlan.steps(for: .checkoutStart), [
            .pullCheckout, .checkNodePackages, .rebuildFrontend, .updatePythonPackages,
            .startServer, .loadPsyNeuLink, .warmModelRunner,
        ])
        // The PsyNeuLink update is never planned: it appears when it begins.
        for path in [ProgressPlan.Path.start, .checkoutStart, .update, .repair] {
            XCTAssertFalse(ProgressPlan.steps(for: path).contains(.installPsyNeuLinkUpdate))
        }
    }

    func testEveryStepHasATitleAndATypicalRange() {
        for step in ProgressStep.allCases {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertLessThan(step.typical.lowerBound, step.typical.upperBound)
        }
    }

    func testEveryInstallerStepHasAPlainTitle() {
        for step in InstallStep.allCases {
            XCTAssertFalse(ProgressStep(step).title.isEmpty)
        }
    }

    // MARK: Stored timings

    func testTimingsKeepTheLastFew() {
        var list: [Double] = []
        for value in 1...8 { list = StepTimings.appending(Double(value), to: list) }
        XCTAssertEqual(list, [4, 5, 6, 7, 8])
        XCTAssertEqual(StepTimings.appending(.nan, to: [1]), [1])
        XCTAssertEqual(StepTimings.appending(-1, to: [1]), [1])
    }

    func testTimingsRoundTripUnderTheirOwnKey() throws {
        let suite = "pnv-196-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let timings = StepTimings(defaults: defaults)
        timings.record(.startServer, seconds: 38.7)
        timings.record(.startServer, seconds: 41)
        XCTAssertEqual(timings.history()[.startServer], [38.7, 41])
        XCTAssertEqual(Array(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("progress") }),
                       [StepTimings.key])
    }

    // MARK: "usually about N s" (#232)

    func testTypicalIsTheMedianOfTheLastFewRuns() {
        XCTAssertNil(ProgressEstimate.typicalSeconds(history: []))
        XCTAssertEqual(ProgressEstimate.typicalSeconds(history: [12]), 12)
        XCTAssertEqual(ProgressEstimate.typicalSeconds(history: [10, 20]), 15)
        // One slow launch doesn't move the typical value much.
        XCTAssertEqual(ProgressEstimate.typicalSeconds(history: [5, 90, 6]), 6)
        // Only the last few count, and junk is ignored.
        XCTAssertEqual(ProgressEstimate.typicalSeconds(history: [500, 500, 500, 1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(ProgressEstimate.typicalSeconds(history: [.nan, -4, 7]), 7)
    }

    func testUsualPhrases() {
        XCTAssertEqual(ProgressEstimate.usualPhrase(seconds: 0.4), "usually under a second")
        XCTAssertEqual(ProgressEstimate.usualPhrase(seconds: 24.6), "usually about 25 s")
        XCTAssertEqual(ProgressEstimate.usualPhrase(seconds: 89), "usually about 89 s")
        XCTAssertEqual(ProgressEstimate.usualPhrase(seconds: 95), "usually about 2 min")
        XCTAssertEqual(ProgressEstimate.usualPhrase(seconds: 240), "usually about 4 min")
    }

    // MARK: Why the first start is slow (#228)

    func testASlowStartAfterNewPackagesIsExplained() {
        let states = [
            State(step: .installPackages, status: .done(seconds: 200)),
            State(step: .startServer, status: .done(seconds: 3)),
            State(step: .loadPsyNeuLink, status: .running(elapsed: 13)),
        ]
        XCTAssertEqual(ProgressEstimate.slowStartNotice(states), ProgressEstimate.slowStartExplanation)
    }

    func testAStartNotYetSlowIsNotExplained() {
        let states = [
            State(step: .installPackages, status: .done(seconds: 200)),
            State(step: .startServer, status: .running(elapsed: 14.9)),
        ]
        XCTAssertNil(ProgressEstimate.slowStartNotice(states))
    }

    func testASlowStartWithNoNewFilesIsNotBlamedOnThem() {
        let states = [
            State(step: .pullCheckout, status: .skipped(reason: "already up to date")),
            State(step: .updatePythonPackages, status: .skipped(reason: "no package changes")),
            State(step: .startServer, status: .running(elapsed: 40)),
        ]
        XCTAssertNil(ProgressEstimate.slowStartNotice(states))
        // A rebuilt interface isn't new Python packages either.
        XCTAssertNil(ProgressEstimate.slowStartNotice([
            State(step: .rebuildFrontend, status: .done(seconds: 9)),
            State(step: .startServer, status: .running(elapsed: 40)),
        ]))
    }

    func testAFinishedStartNeedsNoExplaining() {
        let states = [
            State(step: .updatePythonPackages, status: .done(seconds: 30)),
            State(step: .startServer, status: .done(seconds: 3)),
            State(step: .loadPsyNeuLink, status: .done(seconds: 25)),
            State(step: .warmModelRunner, status: .done(seconds: 2)),
        ]
        XCTAssertNil(ProgressEstimate.slowStartNotice(states))
    }

    func testTheWholeServerStartCountsNotJustTheStepInProgress() {
        let states = [
            State(step: .updatePythonPackages, status: .done(seconds: 30)),
            State(step: .startServer, status: .done(seconds: 10)),
            State(step: .installPsyNeuLinkUpdate, status: .done(seconds: 4)),
            State(step: .loadPsyNeuLink, status: .running(elapsed: 2)),
        ]
        XCTAssertNotNil(ProgressEstimate.slowStartNotice(states))
    }
}
