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
