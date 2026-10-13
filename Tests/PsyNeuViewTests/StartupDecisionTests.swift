import Foundation
import XCTest
@testable import PsyNeuView

/// What should be on screen while starting (#104).
///
/// Three bugs reached users from real installs, none caught by 109 tests,
/// because all three were sequencing rather than logic. Each has a test here
/// named for it.
final class StartupDecisionTests: XCTestCase {

    private func input(
        setupCompleted: Bool = true,
        backendHealthy: Bool = false,
        backendRunning: Bool = true,
        elapsed: TimeInterval = 1,
        ceiling: TimeInterval = 600,
        reassureAfter: TimeInterval = 20
    ) -> StartupDecision.Input {
        .init(setupCompleted: setupCompleted, backendHealthy: backendHealthy,
              backendRunning: backendRunning, elapsed: elapsed,
              ceiling: ceiling, reassureAfter: reassureAfter)
    }

    // MARK: - The three that shipped

    func testAFinishedStartShowsTheAppAndNotTheLog() {
        // #96: a successful install ended on a debug log with no sign the app
        // was coming.
        XCTAssertEqual(StartupDecision.screen(for: input(backendHealthy: true)), .app)
    }

    func testASlowStartIsReassuredNotFailed() {
        // #101: 38.67s of warm-up against a 30s ceiling. Past the reassurance
        // point but under the ceiling must say something, not give up.
        let screen = StartupDecision.screen(for: input(elapsed: 38.67, ceiling: 600))
        XCTAssertEqual(screen, .starting(message: StartupDecision.slowMessage))
    }

    func testRetryIsOfferedOnlyWhenRetryingCanHelp() {
        // #101: the retry button logged "Cannot start" four times, because the
        // process was gone and pressing it again could not change that.
        let processGone = StartupDecision.screen(for: input(backendRunning: false))
        guard case .failed(_, let retryable) = processGone else {
            return XCTFail("a dead process is a failure")
        }
        XCTAssertFalse(retryable)

        // Timing out is different: the install is fine, it was just slow.
        let tooSlow = StartupDecision.screen(for: input(elapsed: 601, ceiling: 600))
        guard case .failed(_, let canRetry) = tooSlow else {
            return XCTFail("exceeding the ceiling is a failure")
        }
        XCTAssertTrue(canRetry)
    }

    // MARK: - The rest of the table

    func testNoSetupMeansTheWizard() {
        XCTAssertEqual(
            StartupDecision.screen(for: input(setupCompleted: false)), .setupWizard)
    }

    func testTheWizardWinsEvenIfSomethingElseLooksReady() {
        // Nothing else can be true before setup has run.
        XCTAssertEqual(
            StartupDecision.screen(for: input(setupCompleted: false, backendHealthy: true)),
            .setupWizard)
    }

    func testAHealthyBackendBeatsADeadProcessFlag() {
        // If it answered, it is up — whatever a stale process flag says.
        // Otherwise a race between the two reads shows a failure over a
        // working app.
        XCTAssertEqual(
            StartupDecision.screen(for: input(backendHealthy: true, backendRunning: false)),
            .app)
    }

    func testAHealthyBackendBeatsTheCeiling() {
        // Arriving late is still arriving. #101 was the app giving up eleven
        // seconds before the backend came good.
        XCTAssertEqual(
            StartupDecision.screen(for: input(backendHealthy: true, elapsed: 10_000)),
            .app)
    }

    func testEarlyOnItJustSaysStarting() {
        XCTAssertEqual(
            StartupDecision.screen(for: input(elapsed: 1)),
            .starting(message: StartupDecision.startingMessage))
    }

    func testTheMessageChangesExactlyAtTheReassurancePoint() {
        let before = StartupDecision.screen(for: input(elapsed: 20, reassureAfter: 20))
        XCTAssertEqual(before, .starting(message: StartupDecision.startingMessage))
        let after = StartupDecision.screen(for: input(elapsed: 20.1, reassureAfter: 20))
        XCTAssertEqual(after, .starting(message: StartupDecision.slowMessage))
    }

    func testADeadProcessFailsWithoutWaitingOutTheCeiling() {
        // Waiting is only useful while something might still answer.
        let screen = StartupDecision.screen(for: input(backendRunning: false, elapsed: 1))
        guard case .failed = screen else {
            return XCTFail("a dead process should not keep the spinner up for ten minutes")
        }
    }

    func testTheFailureSaysHowLongItWaited() {
        // "It didn't start" is not actionable; "not within 10 minutes" is.
        let screen = StartupDecision.screen(for: input(elapsed: 601, ceiling: 600))
        guard case .failed(let reason, _) = screen else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("10"), "expected the wait in the message: \(reason)")
    }
}
