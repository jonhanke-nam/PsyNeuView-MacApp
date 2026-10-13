import XCTest
@testable import PsyNeuView

/// Whether "Update PsyNeuView checkout…" may pull, and what it says when it
/// may not (#214). Fast-forward only, never over uncommitted work, never a
/// branch switch — the same rules as PsyNeuView's per-checkout pull — with
/// the reason in words for the log.
final class CheckoutPullTests: XCTestCase {

    private func state(
        branch: String? = "devel", fetched: Bool = true,
        changedFiles: Int = 0, ahead: Int = 0, behind: Int = 0
    ) -> CheckoutPull.State {
        CheckoutPull.State(
            branch: branch, fetched: fetched, changedFiles: changedFiles,
            ahead: ahead, behind: behind)
    }

    func testACleanCheckoutBehindOriginPulls() {
        XCTAssertEqual(CheckoutPull.decide(state(behind: 3)), .pull(branch: "devel"))
    }

    func testUpToDateIsNothingToPull() {
        XCTAssertEqual(
            CheckoutPull.decide(state()),
            .nothingToPull("devel is up to date with origin/devel."))
    }

    /// Local commits with nothing new on origin: a fast-forward would do
    /// nothing, and that is not a failure.
    func testAheadOnlyIsNothingToPull() {
        XCTAssertEqual(
            CheckoutPull.decide(state(ahead: 2)),
            .nothingToPull("devel is 2 commits ahead of origin/devel; nothing to pull."))
        XCTAssertEqual(
            CheckoutPull.decide(state(ahead: 1)),
            .nothingToPull("devel is 1 commit ahead of origin/devel; nothing to pull."))
    }

    /// The case the issue names: edits in progress, and the pull is refused
    /// with the count, so the developer knows it was their changes and not
    /// the network.
    func testUncommittedChangesRefuseWithTheCount() {
        guard case .refuse(let why) = CheckoutPull.decide(state(changedFiles: 4, behind: 2)) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(why.hasPrefix("4 files changed locally; not pulled."), why)
        XCTAssertTrue(why.contains("stash"), why)

        guard case .refuse(let one) = CheckoutPull.decide(state(changedFiles: 1, behind: 2)) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(one.hasPrefix("1 file changed locally; not pulled."), one)
    }

    /// Uncommitted changes refuse even when there is nothing to pull: the
    /// answer is about the checkout's state, which is what was asked.
    func testUncommittedChangesRefuseBeforeUpToDateIsConsidered() {
        guard case .refuse = CheckoutPull.decide(state(changedFiles: 1)) else {
            return XCTFail("expected a refusal")
        }
    }

    /// Commits on both sides: a fast-forward is impossible and a merge is not
    /// the app's to make. Say which branch, and that it is by hand.
    func testADivergedBranchIsRefused() {
        guard case .refuse(let why) = CheckoutPull.decide(state(ahead: 1, behind: 5)) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(
            why,
            "devel has diverged from origin/devel (1 commit here, 5 commits on origin); "
            + "not pulled. Rebase or merge in the checkout by hand.")
    }

    /// An old checkout after PsyNeuView moved to a fresh public repository:
    /// origin's branch shares no history with it. Say what happened and both
    /// ways on, instead of git's "refusing to merge unrelated histories".
    func testUnrelatedHistoryIsRefusedWithTheMoveExplained() {
        var s = state(ahead: 1500, behind: 1)
        s.unrelated = true
        guard case .refuse(let why) = CheckoutPull.decide(s) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(why, CheckoutPull.unrelatedHistoryMessage)
        XCTAssertTrue(why.contains("fresh public repository"))
        XCTAssertTrue(why.contains("PsyNeuView-archive"))
        XCTAssertEqual(Updater.pullSkipReason(for: s), "PsyNeuView moved to a new repository; not pulled")
    }

    /// Never switch branch: a detached HEAD has no branch to fast-forward, so
    /// the pull is refused rather than resolved by checking something out.
    func testADetachedHeadIsRefused() {
        for branch in [nil, ""] {
            guard case .refuse(let why) = CheckoutPull.decide(state(branch: branch, behind: 1)) else {
                return XCTFail("expected a refusal")
            }
            XCTAssertTrue(why.contains("detached HEAD"), why)
            XCTAssertTrue(why.contains("not pulled"), why)
        }
    }

    /// A failed fetch leaves the counts meaningless; "up to date" would be a
    /// guess, so it refuses and says what to check.
    func testAFailedFetchIsRefused() {
        guard case .refuse(let why) = CheckoutPull.decide(state(fetched: false)) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(why.hasPrefix("Couldn't fetch origin/devel"), why)
        XCTAssertTrue(why.contains("not pulled"), why)
    }

    /// Every refusal says so in the same words, so the log reads one way.
    func testEveryRefusalSaysNotPulled() {
        let refusals = [
            state(branch: nil), state(fetched: false),
            state(changedFiles: 2), state(ahead: 1, behind: 1),
        ]
        for s in refusals {
            guard case .refuse(let why) = CheckoutPull.decide(s) else {
                return XCTFail("expected a refusal for \(s)")
            }
            XCTAssertTrue(why.contains("; not pulled."), why)
        }
    }

    // MARK: Reading git's output

    func testRevListCountsAreAheadThenBehind() {
        XCTAssertTrue(CheckoutPull.counts(fromRevList: "2\t7\n")! == (ahead: 2, behind: 7))
        XCTAssertTrue(CheckoutPull.counts(fromRevList: "0 0")! == (ahead: 0, behind: 0))
    }

    /// Anything unreadable is nil, never zero: "cannot tell" must not become
    /// "up to date".
    func testUnreadableCountsAreNil() {
        XCTAssertNil(CheckoutPull.counts(fromRevList: ""))
        XCTAssertNil(CheckoutPull.counts(fromRevList: "fatal: bad revision"))
        XCTAssertNil(CheckoutPull.counts(fromRevList: "3"))
    }

    func testChangedFilesCountsStatusLines() {
        XCTAssertEqual(CheckoutPull.changedFiles(fromStatus: ""), 0)
        XCTAssertEqual(CheckoutPull.changedFiles(fromStatus: "\n"), 0)
        XCTAssertEqual(
            CheckoutPull.changedFiles(fromStatus: " M backend/app/main.py\nA  frontend/x.ts\n"),
            2)
    }
}
