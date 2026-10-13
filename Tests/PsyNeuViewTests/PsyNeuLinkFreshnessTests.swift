import XCTest
@testable import PsyNeuView

// Offering a PsyNeuLink refresh when the install has fallen behind (#116).
// XCTest (not Swift Testing) so it runs on the CI toolchain's Xcode.

final class PsyNeuLinkUpdateOfferTests: XCTestCase {
    private func decide(
        status: String = "behind",
        behindBy: Int? = 23,
        headDate: String? = "2026-09-15T08:03:40Z",
        suppressed: Bool = false
    ) -> PsyNeuLinkUpdateOffer {
        PsyNeuLinkUpdateOffer.decide(
            status: status, behindBy: behindBy, headDate: headDate, suppressed: suppressed)
    }

    private func isOffer(_ offer: PsyNeuLinkUpdateOffer) -> Bool {
        if case .offer = offer { return true }
        return false
    }

    func testOffersWhenBehind() {
        // The real case: a 0.5.5 install 23 commits behind devel.
        XCTAssertTrue(isOffer(decide()))
    }

    func testSilentWhenLevelWithTheBranch() {
        XCTAssertFalse(isOffer(decide(status: "current", behindBy: 0)))
    }

    func testSilentWhenPinnedToARelease() {
        // A PyPI install has no branch to be behind.
        XCTAssertFalse(isOffer(decide(status: "not_applicable", behindBy: nil)))
    }

    func testAFailedCheckNeverReadsAsAnUpdate() {
        // The whole point of the issue was a stale install looking current.
        // Its mirror is just as bad: "we could not reach GitHub" must not be
        // dressed up as "there is an update waiting".
        XCTAssertFalse(isOffer(decide(status: "unknown", behindBy: nil)))
        XCTAssertFalse(isOffer(decide(status: "unknown", behindBy: 5)))
    }

    func testSilentWhenTheUserSaidNotToAsk() {
        XCTAssertFalse(isOffer(decide(suppressed: true)))
    }

    func testMutingBeatsEverythingElse() {
        // Whatever the report says, a muted user is not interrupted.
        for status in ["behind", "current", "unknown", "not_applicable"] {
            XCTAssertFalse(isOffer(decide(status: status, suppressed: true)), status)
        }
    }

    func testZeroOrMissingCountIsNotAnOffer() {
        // "behind" with nothing to show would produce "0 commits behind".
        XCTAssertFalse(isOffer(decide(behindBy: 0)))
        XCTAssertFalse(isOffer(decide(behindBy: nil)))
    }
}

final class PsyNeuLinkOfferMessageTests: XCTestCase {
    func testNamesTheCountAndBranch() {
        let text = PsyNeuLinkUpdateOffer.message(
            behindBy: 23, branch: "devel", headDate: "2026-09-15T08:03:40Z")
        XCTAssertTrue(text.contains("23 commits behind devel"), text)
        XCTAssertTrue(text.contains("2026-09-15"), text)
    }

    func testOneCommitIsSingular() {
        let text = PsyNeuLinkUpdateOffer.message(behindBy: 1, branch: "devel", headDate: nil)
        XCTAssertTrue(text.contains("1 commit behind"), text)
        XCTAssertFalse(text.contains("1 commits"), text)
    }

    func testSaysWhatUpdatingWillDo() {
        // The user is agreeing to a reinstall and a restart; say so before they
        // click, not after the window disappears.
        let text = PsyNeuLinkUpdateOffer.message(behindBy: 2, branch: "devel", headDate: nil)
        XCTAssertTrue(text.contains("restarts PsyNeuView"), text)
    }

    func testCopesWithoutAHeadDate() {
        let text = PsyNeuLinkUpdateOffer.message(behindBy: 2, branch: "devel", headDate: nil)
        XCTAssertTrue(text.contains("2 commits behind devel"), text)
    }

    func testIgnoresAMalformedHeadDate() {
        let text = PsyNeuLinkUpdateOffer.message(behindBy: 2, branch: "devel", headDate: "oops")
        XCTAssertFalse(text.contains("newest is from"), text)
    }
}

final class PsyNeuLinkFreshnessDecodingTests: XCTestCase {
    func testDecodesTheBackendPayload() throws {
        // Exactly what /api/settings/pnl-freshness returns (#1097).
        let json = """
        {"status":"behind","behind_by":23,"installed_commit":"875890855",
         "head_commit":"9ce038ffa1","head_date":"2026-09-15T08:03:40Z",
         "detail":"23 commits behind devel, newest from 2026-09-15."}
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(PsyNeuLinkFreshness.self, from: json)
        XCTAssertEqual(report.status, "behind")
        XCTAssertEqual(report.behindBy, 23)
        XCTAssertEqual(report.installedCommit, "875890855")
    }

    func testDecodesTheNothingToSayPayload() throws {
        let json = """
        {"status":"not_applicable","behind_by":null,"installed_commit":null,
         "head_commit":null,"head_date":null,
         "detail":"Pinned to a release, so there is no branch to track."}
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(PsyNeuLinkFreshness.self, from: json)
        XCTAssertEqual(report.status, "not_applicable")
        XCTAssertNil(report.behindBy)
    }

    func testBuildsTheLocalEndpointURL() {
        XCTAssertEqual(
            PsyNeuLinkFreshnessCheck.url(port: 51234)?.absoluteString,
            "http://127.0.0.1:51234/api/settings/pnl-freshness")
    }
}
