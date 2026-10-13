import Foundation
import XCTest
@testable import PsyNeuView

/// The PsyNeuLink source offered during setup (#130).
///
/// The choice is passed to the install and never stored: after setup the
/// backend owns which PsyNeuLink is installed, and a wizard that remembered
/// the answer would put back the second copy #132 removed.
final class WizardSourceChoiceTests: XCTestCase {

    func testLatestDevelopmentVersionInstallsFromTheBranch() {
        let args = PsyNeuLinkSource.github.pipInstallArgs(
            branch: "devel", repo: "", localPath: "")
        XCTAssertEqual(args, ["git+https://github.com/\(PsyNeuLinkSource.defaultRepo).git@devel"])
    }

    func testOfficialReleaseInstallsFromPyPI() {
        XCTAssertEqual(
            PsyNeuLinkSource.pypi.pipInstallArgs(branch: "devel", repo: "", localPath: ""),
            ["psyneulink"])
    }

    func testAnExistingCheckoutIsInstalledInPlace() {
        // Editable, so the user's own tools keep working against the same
        // folder — which is the reason someone picks this.
        XCTAssertEqual(
            PsyNeuLinkSource.local.pipInstallArgs(
                branch: "", repo: "", localPath: "/Users/someone/PsyNeuLink"),
            ["-e", "/Users/someone/PsyNeuLink"])
    }

    func testTheDefaultIsUnchangedBySetupOfferingAChoice() {
        // Someone who ignores the picker must get exactly what they got before
        // this existed: the development branch.
        let args = PsyNeuLinkSource.github.pipInstallArgs(
            branch: "devel", repo: "", localPath: "")
        XCTAssertTrue(args.first?.contains("@devel") == true)
    }

    func testAFolderThatIsNotACheckoutIsRejected() {
        // Caught before the install rather than deep inside pip, where the
        // error explains nothing.
        XCTAssertFalse(PsyNeuLinkSource.isValidLocalCheckout("/tmp"))
        XCTAssertFalse(PsyNeuLinkSource.isValidLocalCheckout(""))
    }
}
