import XCTest
@testable import PsyNeuView

/// A first launch nobody can answer installs by itself, and only then (#174).
final class UnattendedSetupTests: XCTestCase {

    private func decide(
        setup: Bool = false, nonInteractive: Bool = true,
        bundled: Bool = true, archive: Bool = true
    ) -> Bool {
        UnattendedSetup.shouldInstall(
            setupCompleted: setup, nonInteractive: nonInteractive,
            useBundledApp: bundled, hasBundledArchive: archive)
    }

    func testAnUnattendedFirstLaunchInstallsByItself() {
        // The release's launch check: a fresh runner, nobody at the wizard.
        XCTAssertTrue(decide())
    }

    func testANormalFirstLaunchStillShowsTheWizard() {
        XCTAssertFalse(decide(nonInteractive: false))
    }

    func testAnAppAlreadySetUpNeverReinstalls() {
        XCTAssertFalse(decide(setup: true))
    }

    func testNoBundledArchiveMeansTheWizard() {
        // Cloning needs choices the defaults can't make.
        XCTAssertFalse(decide(archive: false))
        XCTAssertFalse(decide(bundled: false))
    }

    func testTheDefaultsAreTheWizardsGitHubDevel() {
        XCTAssertEqual(UnattendedSetup.defaultSource, .github)
        XCTAssertEqual(UnattendedSetup.defaultBranch, "devel")
        XCTAssertEqual(
            UnattendedSetup.defaultPipArgs,
            PsyNeuLinkSource.github.pipInstallArgs(branch: "devel"))
    }
}
