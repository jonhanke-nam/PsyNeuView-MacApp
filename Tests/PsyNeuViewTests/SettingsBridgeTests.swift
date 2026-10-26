import Foundation
import XCTest
@testable import PsyNeuView

/// The `pnvSettings` bridge's message handling (#200), over a fake host.
@MainActor
final class SettingsBridgeTests: XCTestCase {

    final class FakeHost: SettingsBridgeHost {
        var autoRestart = false
        var launchAtLogin = false
        var developerMode = false
        var reportSendWith = "ask"
        var reportSendTo = ""
        var loginRefusal: String?
        var decision: InstallSwitch.Decision = .nothingToDo
        var decidedChoices: [InstallSwitch.Choice] = []
        var install = SettingsBridge.InstallState(
            running: "PsyNeuView 0.5.8, included with this app",
            choice: .bundled, includedVersion: "0.5.8",
            recentCheckouts: ["/code/PsyNeuView"])

        func setAutoRestart(_ on: Bool) { autoRestart = on }
        func setLaunchAtLogin(_ on: Bool) -> String? {
            if let loginRefusal { return loginRefusal }
            launchAtLogin = on
            return nil
        }
        func setDeveloperMode(_ on: Bool) { developerMode = on }
        var receiveReleaseCandidates = false
        func setReceiveReleaseCandidates(_ on: Bool) { receiveReleaseCandidates = on }
        func setReportSendWith(_ route: String) { reportSendWith = route }
        func setReportSendTo(_ address: String) { reportSendTo = address }
        func installState() -> SettingsBridge.InstallState { install }
        func decide(_ choice: InstallSwitch.Choice) -> InstallSwitch.Decision {
            decidedChoices.append(choice)
            return decision
        }
        var found: AppUpdateWatch.Found?
        var installRequests = 0
        func appUpdate() -> [String: Any] {
            AppUpdateWatch.bridgeValue(running: "0.5.22", found: found)
        }
        func installAppUpdate() { installRequests += 1 }
        var pnlRecord = "github:devel"
        var pnlSyncRequests = 0
        func syncPsyNeuLinkSource() { pnlSyncRequests += 1; pnlRecord = "local:/checkout" }
    }

    private func reply(_ outcome: SettingsBridge.Outcome) -> [String: Any]? {
        if case .success(let value) = outcome.reply { return value }
        return nil
    }

    private func failure(_ outcome: SettingsBridge.Outcome) -> String? {
        if case .failure(let f) = outcome.reply { return f.message }
        return nil
    }

    func testGetDescribesEverySetting() throws {
        let host = FakeHost()
        host.autoRestart = true
        let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: host)))
        XCTAssertEqual(snapshot["autoRestart"] as? Bool, true)
        XCTAssertEqual(snapshot["launchAtLogin"] as? Bool, false)
        XCTAssertEqual(snapshot["developerMode"] as? Bool, false)
        XCTAssertEqual(snapshot["receiveReleaseCandidates"] as? Bool, false)
        XCTAssertEqual(snapshot["reportSendWith"] as? String, "ask")
        XCTAssertEqual(snapshot["reportSendTo"] as? String, "")
        XCTAssertEqual(snapshot["reportSendToDefault"] as? String, ReportDefaults.contactEmail)
        let install = try XCTUnwrap(snapshot["install"] as? [String: Any])
        XCTAssertEqual(install["choice"] as? String, "bundled")
        XCTAssertTrue(install["checkoutPath"] is NSNull)
        XCTAssertEqual(install["includedVersion"] as? String, "0.5.8")
        XCTAssertEqual(install["running"] as? String, "PsyNeuView 0.5.8, included with this app")
        XCTAssertEqual(install["recentCheckouts"] as? [String], ["/code/PsyNeuView"])
    }

    func testACheckoutInUseIsNamed() throws {
        let host = FakeHost()
        host.install.choice = .checkout("/code/PsyNeuView")
        let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: host)))
        let install = try XCTUnwrap(snapshot["install"] as? [String: Any])
        XCTAssertEqual(install["choice"] as? String, "checkout")
        XCTAssertEqual(install["checkoutPath"] as? String, "/code/PsyNeuView")
    }

    func testSetChangesTheSettingAndRepliesWithTheNewValues() throws {
        let host = FakeHost()
        let a = try XCTUnwrap(reply(SettingsBridge.handle(
            ["op": "set", "key": "autoRestart", "value": true], host: host)))
        XCTAssertTrue(host.autoRestart)
        XCTAssertEqual(a["autoRestart"] as? Bool, true)

        _ = SettingsBridge.handle(["op": "set", "key": "launchAtLogin", "value": true], host: host)
        XCTAssertTrue(host.launchAtLogin)

        _ = SettingsBridge.handle(["op": "set", "key": "developerMode", "value": true], host: host)
        XCTAssertTrue(host.developerMode)

        let c = try XCTUnwrap(reply(SettingsBridge.handle(
            ["op": "set", "key": "receiveReleaseCandidates", "value": true], host: host)))
        XCTAssertTrue(host.receiveReleaseCandidates)
        XCTAssertEqual(c["receiveReleaseCandidates"] as? Bool, true)
    }

    func testARefusedLoginItemRejectsWithTheReason() {
        let host = FakeHost()
        host.loginRefusal = "macOS didn't change the login item: nope"
        let outcome = SettingsBridge.handle(
            ["op": "set", "key": "launchAtLogin", "value": true], host: host)
        XCTAssertEqual(failure(outcome), "macOS didn't change the login item: nope")
        XCTAssertFalse(host.launchAtLogin)
    }

    func testMalformedMessagesAreRejected() {
        let host = FakeHost()
        XCTAssertNotNil(failure(SettingsBridge.handle("get", host: host)))
        XCTAssertNotNil(failure(SettingsBridge.handle(["nope": 1], host: host)))
        XCTAssertNotNil(failure(SettingsBridge.handle(["op": "explode"], host: host)))
        XCTAssertNotNil(failure(SettingsBridge.handle(["op": "set", "value": true], host: host)))
        XCTAssertNotNil(failure(SettingsBridge.handle(
            ["op": "set", "key": "autoRestart", "value": "yes"], host: host)))
        XCTAssertNotNil(failure(SettingsBridge.handle(
            ["op": "set", "key": "pnlSource", "value": true], host: host)))
        XCTAssertFalse(host.autoRestart)
    }

    func testTheInstallIsSwitchedNotSet() {
        let host = FakeHost()
        let outcome = SettingsBridge.handle(["op": "set", "key": "install", "value": true], host: host)
        XCTAssertEqual(failure(outcome), "pnvSettings: switch installs with 'switchInstall'")
    }

    func testCheckInstallSaysWhatWouldHappenAndSwitchesNothing() throws {
        let host = FakeHost()
        host.decision = .useCheckout(path: "/code/PsyNeuView")
        let outcome = SettingsBridge.handle(
            ["op": "checkInstall", "choice": "checkout", "path": "/code/PsyNeuView/"], host: host)
        let verdict = try XCTUnwrap(reply(outcome))
        XCTAssertEqual(verdict["decision"] as? String, "useCheckout")
        XCTAssertEqual(verdict["path"] as? String, "/code/PsyNeuView")
        XCTAssertNil(outcome.switchTo)
        // The path arrives normalized: expanding `~` also drops the trailing
        // slash, so "is this checkout already running?" compares like with like.
        XCTAssertEqual(host.decidedChoices, [.checkout("/code/PsyNeuView")])
    }

    func testSwitchInstallSwitchesOnlyWhenThereIsSomethingToSwitchTo() {
        let host = FakeHost()
        host.decision = .useBundled(version: "0.5.8")
        XCTAssertEqual(
            SettingsBridge.handle(["op": "switchInstall", "choice": "bundled"], host: host).switchTo,
            .useBundled(version: "0.5.8"))

        host.decision = .refuse("There is no folder at /nope.")
        let refused = SettingsBridge.handle(
            ["op": "switchInstall", "choice": "checkout", "path": "/nope"], host: host)
        XCTAssertNil(refused.switchTo)
        XCTAssertEqual(reply(refused)?["decision"] as? String, "refuse")
        XCTAssertEqual(reply(refused)?["message"] as? String, "There is no folder at /nope.")

        host.decision = .nothingToDo
        XCTAssertNil(SettingsBridge.handle(["op": "switchInstall", "choice": "bundled"], host: host).switchTo)
    }

    func testAnUnknownChoiceIsRejected() {
        let host = FakeHost()
        XCTAssertNotNil(failure(SettingsBridge.handle(["op": "checkInstall", "choice": "other"], host: host)))
        XCTAssertTrue(host.decidedChoices.isEmpty)
    }

    func testATypedHomeFolderIsExpanded() {
        let choice = SettingsBridge.choice(from: ["choice": "checkout", "path": " ~/code/PsyNeuView "])
        XCTAssertEqual(choice, .checkout(NSHomeDirectory() + "/code/PsyNeuView"))
    }

    func testEventScriptsCarryTheirDetailAsJSON() {
        let script = SettingsBridge.eventScript("pnv:mac-settings-changed", detail: ["autoRestart": true])
        XCTAssertEqual(
            script,
            "window.dispatchEvent(new CustomEvent(\"pnv:mac-settings-changed\", { detail: {\"autoRestart\":true} }));")
        XCTAssertTrue(SettingsBridge.openSettingsScript.hasPrefix("window.__pnvOpenSettingsRequested = true;"))
        XCTAssertTrue(SettingsBridge.openSettingsScript.contains("\"pnv:open-settings\""))
    }

    // MARK: Report a Problem's settings (#202)

    func testReportSendWithTakesOneOfItsChoices() throws {
        let host = FakeHost()
        for route in ["mail", "outlook", "gmail", "ask"] {
            let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(
                ["op": "set", "key": "reportSendWith", "value": route], host: host)))
            XCTAssertEqual(host.reportSendWith, route)
            XCTAssertEqual(snapshot["reportSendWith"] as? String, route)
        }
        XCTAssertNotNil(failure(SettingsBridge.handle(
            ["op": "set", "key": "reportSendWith", "value": "carrier pigeon"], host: host)))
        XCTAssertNotNil(failure(SettingsBridge.handle(
            ["op": "set", "key": "reportSendWith", "value": true], host: host)))
        XCTAssertEqual(host.reportSendWith, "ask")
    }

    func testReportSendToIsTrimmedAndChecked() throws {
        let host = FakeHost()
        let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(
            ["op": "set", "key": "reportSendTo", "value": "  help@example.org "], host: host)))
        XCTAssertEqual(host.reportSendTo, "help@example.org")
        XCTAssertEqual(snapshot["reportSendTo"] as? String, "help@example.org")

        let refused = SettingsBridge.handle(
            ["op": "set", "key": "reportSendTo", "value": "Someone at the lab"], host: host)
        XCTAssertEqual(failure(refused), "“Someone at the lab” doesn't look like an email address.")
        XCTAssertEqual(host.reportSendTo, "help@example.org")

        // Clearing it is allowed: empty means the default contact.
        _ = SettingsBridge.handle(["op": "set", "key": "reportSendTo", "value": ""], host: host)
        XCTAssertEqual(host.reportSendTo, "")
        XCTAssertNotNil(failure(SettingsBridge.handle(
            ["op": "set", "key": "reportSendTo", "value": false], host: host)))
    }

    func testEmailAddressCheck() {
        XCTAssertEqual(try? SettingsBridge.emailAddress("a@b.co").get(), "a@b.co")
        XCTAssertEqual(try? SettingsBridge.emailAddress("   ").get(), "")
        for bad in ["a@b", "a b@c.d", "a@b.c, d@e.f", "@b.c", "a@@b.c"] {
            XCTAssertNil(try? SettingsBridge.emailAddress(bad).get(), bad)
        }
    }

    // MARK: App update (#6)

    func testSnapshotSaysWhetherAnAppUpdateIsWaiting() throws {
        let host = FakeHost()
        var snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: host)))
        XCTAssertEqual((snapshot["appUpdate"] as? [String: Any])?["available"] as? Bool, false)

        host.found = AppUpdateWatch.Found(version: "0.6.0", releaseNotesURL: nil)
        snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: host)))
        let update = try XCTUnwrap(snapshot["appUpdate"] as? [String: Any])
        XCTAssertEqual(update["available"] as? Bool, true)
        XCTAssertEqual(update["version"] as? String, "0.6.0")
    }

    func testInstallUpdateOpensSparkleAndRepliesWithASnapshot() throws {
        let host = FakeHost()
        host.found = AppUpdateWatch.Found(version: "0.6.0", releaseNotesURL: nil)
        let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "installUpdate"], host: host)))
        XCTAssertEqual(host.installRequests, 1)
        XCTAssertNotNil(snapshot["appUpdate"])
    }

    // MARK: Release dates (#15)

    func testSnapshotSaysWhenTheIncludedPsyNeuViewWasReleased() throws {
        let host = FakeHost()
        var snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: host)))
        XCTAssertTrue((snapshot["install"] as? [String: Any])?["includedReleasedAt"] is NSNull)

        host.install.includedReleasedAt = Date(timeIntervalSince1970: 1_792_173_776)
        snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: host)))
        XCTAssertEqual((snapshot["install"] as? [String: Any])?["includedReleasedAt"] as? String,
                       "2026-10-16T18:02:56Z")
    }

    func testSnapshotDescribesTheApp() throws {
        let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: FakeHost())))
        let app = try XCTUnwrap(snapshot["app"] as? [String: Any])
        XCTAssertNotNil(app["name"] as? String)
        // The test bundle has no PNVBuildDate: null, not a made-up date.
        XCTAssertTrue(app["builtAt"] is NSNull)
    }

    func testSnapshotCarriesThePsyNeuLinkRecord() throws {
        let host = FakeHost()
        let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "get"], host: host)))
        XCTAssertEqual(snapshot["pnlRecord"] as? String, "github:devel")
    }

    func testSyncPnlSourceRereadsAndRepliesWithTheNewRecord() throws {
        let host = FakeHost()
        let snapshot = try XCTUnwrap(reply(SettingsBridge.handle(["op": "syncPnlSource"], host: host)))
        XCTAssertEqual(host.pnlSyncRequests, 1)
        XCTAssertEqual(snapshot["pnlRecord"] as? String, "local:/checkout")
    }
}
