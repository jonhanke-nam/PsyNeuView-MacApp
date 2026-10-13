import Foundation
import XCTest
@testable import PsyNeuView

/// Saying how old the installed PsyNeuLink is (#116).
///
/// The launch-time offer already existed, but it can be muted and it needs a
/// network. Settings still said "Branch / ref: devel" and nothing else — which
/// reads as current however far behind the pin has drifted. One real install
/// was 111 commits and seven weeks behind while displaying exactly that.
final class PsyNeuLinkStalenessTests: XCTestCase {

    private func freshness(
        status: String, behindBy: Int? = nil, detail: String = ""
    ) -> PsyNeuLinkFreshness {
        PsyNeuLinkFreshness(
            status: status, behindBy: behindBy, installedCommit: nil,
            headCommit: nil, headDate: nil, detail: detail)
    }

    func testBehindShowsTheBackendsSentence() {
        // Reusing the backend's wording keeps one description of "how far
        // behind" rather than two that can disagree.
        let real = "111 commits behind jonhanke-dev, newest from 2026-07-29."
        let s = PsyNeuLinkStaleness.describe(freshness(status: "behind", behindBy: 111, detail: real))
        XCTAssertTrue(s.isBehind)
        XCTAssertEqual(s.text, real)
    }

    func testBehindWithNoDetailStillSaysSomethingTrue() {
        let s = PsyNeuLinkStaleness.describe(freshness(status: "behind", behindBy: 3))
        XCTAssertTrue(s.isBehind)
        XCTAssertFalse(s.text.isEmpty)
    }

    func testCurrentIsNotFlaggedAsAProblem() {
        let s = PsyNeuLinkStaleness.describe(freshness(status: "current"))
        XCTAssertFalse(s.isBehind)
    }

    func testAPinnedReleaseIsNotStale() {
        // It is not drifting — it is what was asked for. Calling it stale would
        // nag someone who deliberately pinned.
        for status in ["not_a_branch", "pinned"] {
            XCTAssertFalse(PsyNeuLinkStaleness.describe(freshness(status: status)).isBehind)
        }
    }

    func testAFailedCheckIsNotReportedAsFine() {
        // "We could not tell" and "it is up to date" are different answers, and
        // silence reads as the second.
        let s = PsyNeuLinkStaleness.describe(nil)
        XCTAssertFalse(s.isBehind)
        XCTAssertTrue(s.text.contains("Could not check"))
    }

    func testAnUnrecognisedStatusIsNotGuessedAt() {
        let s = PsyNeuLinkStaleness.describe(freshness(status: "something-new"))
        XCTAssertFalse(s.isBehind)
    }

    func testAnUnrecognisedStatusWithDetailShowsIt() {
        let s = PsyNeuLinkStaleness.describe(
            freshness(status: "error", detail: "GitHub rate limit reached."))
        XCTAssertEqual(s.text, "GitHub rate limit reached.")
    }
}
