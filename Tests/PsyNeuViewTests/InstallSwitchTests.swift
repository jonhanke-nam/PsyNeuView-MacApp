import XCTest
@testable import PsyNeuView

/// Switching between the included PsyNeuView and a checkout in Settings (#195).
final class InstallSwitchTests: XCTestCase {

    private let bundled058 = InstallSwitch.Facts(
        exists: true, hasGitDir: false, hasMakefile: false,
        hasBackend: true, hasBuiltFrontend: true, stampedVersion: "0.5.8")
    private let checkout = InstallSwitch.Facts(
        exists: true, hasGitDir: true, hasMakefile: true,
        hasBackend: true, hasBuiltFrontend: true, stampedVersion: nil)

    // MARK: Included with this app

    func testSwitchingFromACheckoutToTheIncludedVersion() {
        XCTAssertEqual(
            InstallSwitch.decide(
                choice: .bundled, currentPath: "/code/PsyNeuView", current: checkout,
                archiveVersion: "0.5.8", target: nil),
            .useBundled(version: "0.5.8"))
    }

    func testAlreadyOnTheIncludedVersionIsNothingToDo() {
        XCTAssertEqual(
            InstallSwitch.decide(
                choice: .bundled, currentPath: "/support/psyneuview-0.5.8",
                current: bundled058, archiveVersion: "0.5.8", target: nil),
            .nothingToDo)
    }

    func testAnOlderIncludedVersionSwitchesToTheAppsOwn() {
        var older = bundled058
        older.stampedVersion = "0.5.6"
        XCTAssertEqual(
            InstallSwitch.decide(
                choice: .bundled, currentPath: "/support/psyneuview-0.5.6",
                current: older, archiveVersion: "0.5.8", target: nil),
            .useBundled(version: "0.5.8"))
    }

    func testABuildWithoutAnArchiveRefusesTheIncludedChoice() {
        guard case .refuse(let why) = InstallSwitch.decide(
            choice: .bundled, currentPath: "/code/PsyNeuView", current: checkout,
            archiveVersion: nil, target: nil)
        else { return XCTFail("expected a refusal") }
        XCTAssertTrue(why.contains("doesn't include PsyNeuView"))
    }

    func testFirstChoiceWithNothingInstalledUsesTheIncludedVersion() {
        XCTAssertEqual(
            InstallSwitch.decide(
                choice: .bundled, currentPath: nil, current: nil,
                archiveVersion: "0.5.8", target: nil),
            .useBundled(version: "0.5.8"))
    }

    // MARK: A checkout

    func testSwitchingToAValidCheckout() {
        XCTAssertEqual(
            InstallSwitch.decide(
                choice: .checkout("/code/PsyNeuView/"), currentPath: "/support/psyneuview-0.5.8",
                current: bundled058, archiveVersion: "0.5.8", target: checkout),
            .useCheckout(path: "/code/PsyNeuView"))
    }

    func testTheCheckoutInUseIsNothingToDo() {
        XCTAssertEqual(
            InstallSwitch.decide(
                choice: .checkout("/code/PsyNeuView"), currentPath: "/code/PsyNeuView/",
                current: checkout, archiveVersion: "0.5.8", target: checkout),
            .nothingToDo)
    }

    private func refusal(_ choice: InstallSwitch.Choice, target: InstallSwitch.Facts?) -> String? {
        if case .refuse(let why) = InstallSwitch.decide(
            choice: choice, currentPath: "/support/psyneuview-0.5.8", current: bundled058,
            archiveVersion: "0.5.8", target: target) {
            return why
        }
        return nil
    }

    func testAnEmptyPathIsRefused() {
        XCTAssertNotNil(refusal(.checkout("  "), target: nil))
    }

    func testAMissingFolderIsRefusedWithItsPath() {
        let why = refusal(.checkout("/gone/PsyNeuView"), target: .missing)
        XCTAssertEqual(why, "There is no folder at /gone/PsyNeuView.")
    }

    func testAnUnrelatedFolderIsRefused() {
        let other = InstallSwitch.Facts(
            exists: true, hasGitDir: false, hasMakefile: false,
            hasBackend: false, hasBuiltFrontend: false, stampedVersion: nil)
        XCTAssertTrue(refusal(.checkout("/Users/x/Documents"), target: other)?
            .contains("isn't a PsyNeuView checkout") ?? false)
    }

    func testTheAppsOwnUnpackedFolderIsNotACheckout() {
        XCTAssertTrue(refusal(.checkout("/support/psyneuview-0.5.6"), target: bundled058)?
            .contains("Included with this app") ?? false)
    }

    func testACheckoutWithoutABackendIsRefused() {
        var noBackend = checkout
        noBackend.hasBackend = false
        XCTAssertNotNil(refusal(.checkout("/code/half"), target: noBackend))
    }

    func testACheckoutWithAnUnbuiltFrontendIsRefusedWithWhatToDo() {
        var unbuilt = checkout
        unbuilt.hasBuiltFrontend = false
        XCTAssertTrue(refusal(.checkout("/code/fresh"), target: unbuilt)?
            .contains("npm run build") ?? false)
    }

    func testACheckoutWithoutGitStillCounts() {
        // A downloaded zip has a Makefile but no .git.
        var zip = checkout
        zip.hasGitDir = false
        XCTAssertEqual(InstallSwitch.kind(of: zip), .checkout)
    }

    // MARK: Starting selection, remembered list, descriptions

    func testTheChoiceStartsOnWhatIsRunning() {
        XCTAssertEqual(InstallSwitch.choice(currentPath: "/s/psyneuview-0.5.8", current: bundled058), .bundled)
        XCTAssertEqual(InstallSwitch.choice(currentPath: "/code/P/", current: checkout), .checkout("/code/P"))
        XCTAssertEqual(InstallSwitch.choice(currentPath: nil, current: nil), .bundled)
    }

    func testRememberingMovesToTheFrontWithoutDuplicates() {
        let list = InstallSwitch.remembering("/b", in: ["/a", "/b/", "/c"])
        XCTAssertEqual(list, ["/b", "/a", "/c"])
    }

    func testRememberingIsCapped() {
        let list = InstallSwitch.remembering("/new", in: ["/1", "/2", "/3"], limit: 3)
        XCTAssertEqual(list, ["/new", "/1", "/2"])
    }

    func testBranchFromHEAD() {
        XCTAssertEqual(InstallSwitch.branch(fromHEAD: "ref: refs/heads/devel\n"), "devel")
        XCTAssertEqual(InstallSwitch.branch(fromHEAD: "ref: refs/heads/feat/x"), "feat/x")
        XCTAssertEqual(InstallSwitch.branch(fromHEAD: "9ada5aa0123456789abcdef\n"), "9ada5aa")
        XCTAssertNil(InstallSwitch.branch(fromHEAD: ""))
    }

    func testDescriptionsInPlainWords() {
        XCTAssertEqual(
            InstallSwitch.describe(path: "/s/psyneuview-0.5.8", facts: bundled058, branch: nil),
            "PsyNeuView 0.5.8, included with this app")
        XCTAssertEqual(
            InstallSwitch.describe(
                path: "/Users/x/code/PsyNeuView", facts: checkout, branch: "devel", home: "/Users/x"),
            "Your PsyNeuView checkout at ~/code/PsyNeuView, on branch devel")
        XCTAssertEqual(
            InstallSwitch.describe(path: nil, facts: nil, branch: nil),
            "PsyNeuView isn't installed yet")
    }

    func testFactsReadFromDisk() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-195-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("backend"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("frontend/dist"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try "<html>".write(to: tmp.appendingPathComponent("frontend/dist/index.html"),
                           atomically: true, encoding: .utf8)
        try "ref: refs/heads/devel\n".write(to: tmp.appendingPathComponent(".git/HEAD"),
                                            atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tmp) }

        XCTAssertEqual(InstallSwitch.facts(at: tmp), checkout)
        XCTAssertEqual(InstallSwitch.currentBranch(at: tmp), "devel")
        XCTAssertEqual(InstallSwitch.facts(at: tmp.appendingPathComponent("nope")), .missing)
    }
}
