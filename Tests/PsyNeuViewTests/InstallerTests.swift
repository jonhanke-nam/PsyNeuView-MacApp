import XCTest
@testable import PsyNeuView

// Installing the chosen PsyNeuLink source once rather than twice (#115).
// XCTest (not Swift Testing) so it runs on the CI toolchain's Xcode.

final class InstallOrderTests: XCTestCase {
    let devel = ["git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"]

    func testFreshVenvInstallsTheChosenSourceFirst() {
        // The common case. The default source is the Princeton devel branch and
        // the venv was just created, so installing it first avoids pulling the
        // PyPI wheel only to throw it away moments later.
        XCTAssertTrue(Installer.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: devel, venvAlreadyHasPsyNeuLink: false))
    }

    func testPlainPyPINeedsNoReorder() {
        // Nothing is being overridden, so there is no duplicate to avoid and the
        // backend install can supply psyneulink itself.
        XCTAssertFalse(Installer.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: ["psyneulink"], venvAlreadyHasPsyNeuLink: false))
        XCTAssertFalse(Installer.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: ["psyneulink"], venvAlreadyHasPsyNeuLink: true))
    }

    func testPopulatedVenvKeepsTheOverridePath() {
        // A repair, or a source change. The early install omits
        // --force-reinstall, so it could not replace an existing build; only the
        // later override can, without dragging the whole dependency tree along.
        XCTAssertFalse(Installer.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: devel, venvAlreadyHasPsyNeuLink: true))
    }

    func testALocalCheckoutIsTreatedLikeAnyOtherNonPyPISource() {
        let local = ["-e", "/Users/someone/PsyNeuLink"]
        XCTAssertTrue(Installer.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: local, venvAlreadyHasPsyNeuLink: false))
        XCTAssertFalse(Installer.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: local, venvAlreadyHasPsyNeuLink: true))
    }

    func testAForkCountsAsANonDefaultSource() {
        XCTAssertTrue(Installer.shouldInstallPsyNeuLinkFirst(
            pnlPipArgs: ["git+https://github.com/jonhanke-nam/PsyNeuLink.git@devel"],
            venvAlreadyHasPsyNeuLink: false))
    }
}
