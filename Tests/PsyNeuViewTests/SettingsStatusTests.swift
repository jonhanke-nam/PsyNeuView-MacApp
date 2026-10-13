import Foundation
import XCTest
@testable import PsyNeuView

/// Settings names what was saved, so the user can check it's what they meant (#172).
final class SettingsStatusTests: XCTestCase {

    func testPyPIIsNamedPlainly() {
        XCTAssertEqual(PsyNeuLinkSource.pypi.displayName(branch: "devel", repo: "", localPath: ""), "PyPI")
    }

    func testGitHubNamesTheRepoAndBranch() {
        XCTAssertEqual(
            PsyNeuLinkSource.github.displayName(branch: "devel", repo: "someone/PsyNeuLink", localPath: ""),
            "GitHub someone/PsyNeuLink @ devel")
    }

    func testGitHubFallsBackToTheDefaultRepo() {
        XCTAssertEqual(
            PsyNeuLinkSource.github.displayName(branch: "master", repo: "  ", localPath: ""),
            "GitHub \(PsyNeuLinkSource.defaultRepo) @ master")
    }

    func testALocalCheckoutUnderHomeIsShownWithATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            PsyNeuLinkSource.local.displayName(branch: "", repo: "", localPath: home + "/code/PsyNeuLink"),
            "your checkout at ~/code/PsyNeuLink")
    }

    func testALocalCheckoutElsewhereKeepsItsPath() {
        XCTAssertEqual(
            PsyNeuLinkSource.local.displayName(branch: "", repo: "", localPath: "/opt/PsyNeuLink"),
            "your checkout at /opt/PsyNeuLink")
    }
}
