import XCTest

@testable import PsyNeuView

/// Setup installs from the bundled PsyNeuView's `backend/uv.lock` when it has
/// one (PsyNeuView#247): every package at the version the release's CI
/// tested, then the user's chosen PsyNeuLink on top.
final class InstallFromLockTests: XCTestCase {

    private let args = PsyNeuLinkInstall.lockSyncArguments()

    func testSyncsTheLockAsWritten() {
        XCTAssertEqual(args.first, "sync")
        XCTAssertTrue(args.contains("--frozen"), "never re-resolve on a user's Mac")
    }

    /// The chosen PsyNeuLink goes in afterwards. Installing the lock's only
    /// to replace it would fetch and build PsyNeuLink twice.
    func testLeavesPsyNeuLinkToTheChosenSource() {
        guard let i = args.firstIndex(of: "--no-install-package") else {
            return XCTFail("psyneulink must be left out of the sync")
        }
        XCTAssertEqual(args[i + 1], "psyneulink")
    }

    /// A package a user added for a model survives a repair.
    func testKeepsAnythingElseInTheEnvironment() {
        XCTAssertTrue(args.contains("--inexact"))
    }

    func testUsesTheBundledPythonAndClonesFromTheCache() {
        XCTAssertTrue(args.contains("--no-python-downloads"))
        XCTAssertTrue(args.contains("--link-mode=\(PsyNeuLinkInstall.linkMode)"))
    }

    /// The lock decides versions; nothing here may override it.
    func testNothingUpgradesPastTheLock() {
        for flag in ["--upgrade", "-U", "--refresh", "--reinstall"] {
            XCTAssertFalse(args.contains(flag), "\(flag) would move past the lock")
        }
    }

    func testTheLockIsLookedForUnderItsUsualName() {
        XCTAssertEqual(PsyNeuLinkInstall.lockFileName, "uv.lock")
    }
}
