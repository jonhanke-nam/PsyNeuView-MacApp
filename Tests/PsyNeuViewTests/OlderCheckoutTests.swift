import XCTest
@testable import PsyNeuView

/// An app update runs the newest PsyNeuView, even if a checkout was in use
/// (#16): an older checkout is left for the included copy after an update,
/// and offered the switch on other launches. A current or newer checkout,
/// someone developing PsyNeuView, is left alone.
final class OlderCheckoutTests: XCTestCase {

    private func decide(
        isCheckout: Bool = true, checkout: String? = "0.5.16", archive: String? = "0.6.1",
        seen: String = "0.6.1", keptFor: String = ""
    ) -> OlderCheckout.Decision {
        OlderCheckout.decide(
            isCheckout: isCheckout, checkoutVersion: checkout, archiveVersion: archive,
            includedVersionSeen: seen, keptFor: keptFor)
    }

    func testAnUpdateSwitchesAnOlderCheckoutToTheIncludedCopy() {
        // The demo Mac: updated to 0.6.1 while running a 0.5.16 checkout.
        XCTAssertEqual(decide(seen: "0.6.0"), .switchNow(to: "0.6.1", from: "0.5.16"))
    }

    func testTheFirstLaunchThatRecordsAVersionCountsAsAnUpdate() {
        // Nothing recorded yet: this is the update that brings the check.
        XCTAssertEqual(decide(seen: ""), .switchNow(to: "0.6.1", from: "0.5.16"))
    }

    func testOutsideAnUpdateAnOlderCheckoutIsOfferedTheSwitch() {
        XCTAssertEqual(decide(seen: "0.6.1"), .offer(to: "0.6.1", from: "0.5.16"))
    }

    func testKeepMyCheckoutHoldsUntilTheNextUpdate() {
        XCTAssertEqual(decide(seen: "0.6.1", keptFor: "0.6.1"), .stay)
        // The next update switches again; an older "keep" doesn't count.
        XCTAssertEqual(
            decide(archive: "0.6.2", seen: "0.6.1", keptFor: "0.6.1"),
            .switchNow(to: "0.6.2", from: "0.5.16"))
    }

    func testACurrentOrNewerCheckoutIsLeftAlone() {
        XCTAssertEqual(decide(checkout: "0.6.1", seen: "0.6.0"), .stay)
        XCTAssertEqual(decide(checkout: "0.7.0", seen: "0.6.0"), .stay)
        // Numeric, not alphabetical: 0.6.10 is newer than 0.6.9.
        XCTAssertEqual(decide(checkout: "0.6.10", archive: "0.6.9", seen: ""), .stay)
    }

    func testUnknownVersionsNeverMoveAnything() {
        XCTAssertEqual(decide(checkout: nil, seen: ""), .stay)
        XCTAssertEqual(decide(archive: nil, seen: ""), .stay)
    }

    func testAnIncludedInstallIsNotThisRulesBusiness() {
        // BundledUpgrade (#186) moves included installs.
        XCTAssertEqual(decide(isCheckout: false, seen: ""), .stay)
    }

    func testTheDeclaredVersionIsReadFromInitPy() {
        XCTAssertEqual(OlderCheckout.declaredVersion(fromInit: "__version__ = \"0.6.1\"\n"), "0.6.1")
        XCTAssertEqual(
            OlderCheckout.declaredVersion(fromInit: "\"\"\"PsyNeuView.\"\"\"\n\n__version__='0.5.16'\n"),
            "0.5.16")
        XCTAssertNil(OlderCheckout.declaredVersion(fromInit: "# no version here\n"))
        XCTAssertNil(OlderCheckout.declaredVersion(fromInit: "__version__ = \"\"\n"))
    }

    func testTheDeclaredVersionIsReadFromACheckoutFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("older-checkout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("backend/app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "__version__ = \"0.5.16\"\n".write(
            to: app.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        XCTAssertEqual(OlderCheckout.declaredVersion(atCheckout: root), "0.5.16")
        XCTAssertNil(OlderCheckout.declaredVersion(atCheckout: root.appendingPathComponent("nope")))
    }

    func testTheNoticeSaysWhatHappenedAndHowToGoBack() {
        let notice = OlderCheckout.switchedNotice(to: "0.6.1", from: "0.5.16")
        XCTAssertTrue(notice.contains("Updated to PsyNeuView 0.6.1"), notice)
        XCTAssertTrue(notice.contains("(0.5.16)"), notice)
        XCTAssertTrue(notice.contains("Settings ▸ Developer"), notice)
    }

    func testTheRunningLineNamesACheckoutsVersion() {
        let checkout = InstallSwitch.Facts(
            exists: true, hasGitDir: true, hasMakefile: true, hasBackend: true,
            hasBuiltFrontend: true, stampedVersion: nil)
        XCTAssertEqual(
            InstallSwitch.describe(
                path: "/Users/u/PsyNeuView", facts: checkout, branch: "devel", version: "0.5.16",
                home: "/Users/u"),
            "Your PsyNeuView checkout (0.5.16) at ~/PsyNeuView, on branch devel")
        XCTAssertEqual(
            InstallSwitch.describe(
                path: "/Users/u/PsyNeuView", facts: checkout, branch: nil, home: "/Users/u"),
            "Your PsyNeuView checkout at ~/PsyNeuView")
    }
}
