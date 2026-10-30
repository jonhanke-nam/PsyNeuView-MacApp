import XCTest
@testable import PsyNeuView

/// When a launch moves to the PsyNeuView the app carries (#186).
final class BundledUpgradeTests: XCTestCase {

    func testAnOlderBundledInstallMovesToTheAppsVersion() {
        // The reported case: app 0.5.13 carries 0.5.8, the folder in use holds 0.5.6.
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: "0.5.6", archiveVersion: "0.5.8"),
            .move(to: "0.5.8"))
    }

    func testTheSameVersionStays() {
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: "0.5.8", archiveVersion: "0.5.8"),
            .stay)
    }

    func testTheNextCandidateMoves() {
        // 0.6.7-rc3 shipped v0.6.9-rc3 stamped "0.6.9", the same as rc1's, so
        // it stayed on rc1's code. Each tag now has its own version.
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: "0.6.9-rc1", archiveVersion: "0.6.9-rc3"),
            .move(to: "0.6.9-rc3"))
    }

    func testTheFinalMovesFromItsCandidate() {
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: "0.6.9-rc3", archiveVersion: "0.6.9"),
            .move(to: "0.6.9"))
    }

    func testACandidateMovesFromAnInstallStampedWithoutItsTag() {
        // The installs rc1 to rc3 left behind, stamped plain "0.6.9".
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: "0.6.9", archiveVersion: "0.6.9-rc4"),
            .move(to: "0.6.9-rc4"))
    }

    func testAGitCheckoutIsNeverMoved() {
        // A developer's clone updates by pulling, whatever the app carries.
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: true, treeVersion: nil, archiveVersion: "0.5.8"),
            .stay)
    }

    func testABuildWithNoArchiveStays() {
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: "0.5.6", archiveVersion: nil),
            .stay)
    }

    func testAnUnstampedFolderMoves() {
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: nil, archiveVersion: "0.5.8"),
            .move(to: "0.5.8"))
    }

    func testANewerFolderMovesBackToWhatTheAppCarries() {
        // The app's own PsyNeuView is the one it was tested with.
        XCTAssertEqual(
            BundledUpgrade.decide(isGitCheckout: false, treeVersion: "0.5.9", archiveVersion: "0.5.8"),
            .move(to: "0.5.8"))
    }
}
