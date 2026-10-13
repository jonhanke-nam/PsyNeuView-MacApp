import Foundation
import XCTest
@testable import PsyNeuView

/// A PsyNeuView too old for the app's Settings (#205): the version rule, the
/// offer's wording, and reading the version from an install.
final class SettingsSupportTests: XCTestCase {

    // MARK: The rule

    func testTheMinimumIsTheFirstReleaseWithTheMacAppSection() {
        XCTAssertEqual(SettingsSupport.minimumVersion, "0.5.9")
    }

    func testOlderVersionsAreTooOld() {
        XCTAssertEqual(SettingsSupport.verdict(version: "0.5.6"), .tooOld(version: "0.5.6"))
        XCTAssertEqual(SettingsSupport.verdict(version: "0.5.8"), .tooOld(version: "0.5.8"))
        XCTAssertEqual(SettingsSupport.verdict(version: "0.1.0"), .tooOld(version: "0.1.0"))
    }

    func testTheMinimumAndLaterAreSupported() {
        XCTAssertEqual(SettingsSupport.verdict(version: "0.5.9"), .supported)
        XCTAssertEqual(SettingsSupport.verdict(version: "0.5.10"), .supported)
        XCTAssertEqual(SettingsSupport.verdict(version: "0.6.0"), .supported)
        XCTAssertEqual(SettingsSupport.verdict(version: "1.0"), .supported)
    }

    /// A development build's version says nothing about its age, and an
    /// unreadable one is no reason to interrupt anyone.
    func testDevelopmentAndUnknownVersionsAreNotFlagged() {
        XCTAssertEqual(SettingsSupport.verdict(version: "0.0.0-dev.463bd6f"), .unknown)
        XCTAssertEqual(SettingsSupport.verdict(version: nil), .unknown)
        XCTAssertEqual(SettingsSupport.verdict(version: ""), .unknown)
        XCTAssertEqual(SettingsSupport.verdict(version: "unknown"), .unknown)
        XCTAssertFalse(SettingsSupport.isTooOld("0.0.0-dev.463bd6f"))
        XCTAssertFalse(SettingsSupport.isTooOld(nil))
    }

    // MARK: The offer

    /// The reported case: an old checkout, and an app that carries 0.5.9.
    func testAnOldCheckoutIsOfferedTheIncludedVersionAndAPull() {
        let offer = SettingsSupport.offer(
            version: "0.5.6", running: "Your PsyNeuView checkout at ~/code/PsyNeuView, on branch devel",
            isCheckout: true, archiveVersion: "0.5.9")
        XCTAssertEqual(offer.switchToVersion, "0.5.9")
        XCTAssertTrue(offer.message.contains("PsyNeuView 0.5.6 (Your PsyNeuView checkout at ~/code/PsyNeuView"))
        XCTAssertTrue(offer.message.contains("need PsyNeuView 0.5.9 or later"))
        XCTAssertTrue(offer.message.contains("Your checkout stays where it is"))
        XCTAssertTrue(offer.message.contains("git pull"))
    }

    func testAnOldIncludedInstallIsOfferedTheNewerIncludedOne() {
        let offer = SettingsSupport.offer(
            version: "0.5.6", running: "PsyNeuView 0.5.6, included with this app",
            isCheckout: false, archiveVersion: "0.5.9")
        XCTAssertEqual(offer.switchToVersion, "0.5.9")
        XCTAssertTrue(offer.message.contains("Nothing is deleted."))
        XCTAssertFalse(offer.message.contains("git pull"))
    }

    /// Switching to something just as old would only repeat the problem.
    func testNoSwitchIsOfferedWhenTheIncludedVersionIsAlsoTooOld() {
        let offer = SettingsSupport.offer(
            version: "0.5.6", running: "PsyNeuView 0.5.6, included with this app",
            isCheckout: false, archiveVersion: "0.5.8")
        XCTAssertNil(offer.switchToVersion)
        XCTAssertTrue(offer.message.contains("Report a Problem"))
    }

    func testNoSwitchIsOfferedWithoutAnIncludedVersion() {
        let offer = SettingsSupport.offer(
            version: "0.5.6", running: "Your PsyNeuView checkout at ~/code/PsyNeuView",
            isCheckout: true, archiveVersion: nil)
        XCTAssertNil(offer.switchToVersion)
        XCTAssertTrue(offer.message.contains("git pull"))
    }

    /// "Not Now" quiets one install at one version; a newer one asks again.
    func testDismissalIsPerInstallAndVersion() {
        let a = SettingsSupport.dismissalKey(path: "/code/PsyNeuView", version: "0.5.6")
        XCTAssertNotEqual(a, SettingsSupport.dismissalKey(path: "/code/PsyNeuView", version: "0.5.7"))
        XCTAssertNotEqual(a, SettingsSupport.dismissalKey(path: "/other/PsyNeuView", version: "0.5.6"))
    }

    func testTheReportSaysWhenItIsTooOld() {
        XCTAssertEqual(
            SettingsSupport.reportLine(.tooOld(version: "0.5.6")),
            "too old: 0.5.6 is older than 0.5.9, which the app's Settings need")
        XCTAssertTrue(SettingsSupport.reportLine(.supported).hasPrefix("has the Mac app section"))
    }

    // MARK: Reading the version

    func testTheVersionIsReadFromInitPy() {
        XCTAssertEqual(SettingsSupport.version(fromInitPy: "__version__ = \"0.5.9\"\n"), "0.5.9")
        XCTAssertEqual(SettingsSupport.version(fromInitPy: "\"\"\"Doc.\"\"\"\n__version__='0.1.0'\n"), "0.1.0")
        XCTAssertNil(SettingsSupport.version(fromInitPy: "from .x import y\n"))
    }

    /// A checkout has no BUNDLED_VERSION; its backend says which it is.
    func testACheckoutsVersionComesFromItsBackend() throws {
        let tree = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tree) }
        let app = tree.appendingPathComponent("backend/app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "__version__ = \"0.5.6\"\n".write(
            to: app.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SettingsSupport.version(at: tree), "0.5.6")

        // An install from the app's archive is stamped, and the stamp wins.
        try "version=0.5.9\n".write(
            to: tree.appendingPathComponent("BUNDLED_VERSION"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SettingsSupport.version(at: tree), "0.5.9")
    }

    func testAFolderWithNeitherHasNoVersion() {
        XCTAssertNil(SettingsSupport.version(at: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")))
    }
}
