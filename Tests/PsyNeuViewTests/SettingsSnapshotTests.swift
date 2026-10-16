import Foundation
import XCTest
@testable import PsyNeuView

/// Every app setting in the report (#208): the shape of the section, and
/// that nothing personal or secret gets through.
final class SettingsSnapshotTests: XCTestCase {

    static let home = "/Users/someone"
    static let utc = TimeZone(identifier: "UTC")!
    // 2026-10-06 14:03:22 UTC
    static let date = Date(timeIntervalSince1970: 1_791_295_402)

    static let values = SettingsSnapshot.Values(
        repoPath: "/Users/someone/Library/Application Support/PsyNeuView/app",
        useBundledApp: true,
        branch: "devel",
        autoRestart: true,
        launchAtLogin: false,
        developerMode: true,
        pnlSource: "github",
        pnlBranch: "devel",
        pnlRepo: "",
        pnlLocalPath: "",
        pnlUpdateOffersMuted: false,
        recentCheckouts: ["/Users/someone/code/PsyNeuView", "/Users/someone/old/PsyNeuView"],
        reportSendWith: "ask",
        reportSendTo: ReportDefaults.contactEmail,
        lastMoveOutcome: "2026-10-05 09:12: moved to PsyNeuView 0.5.9",
        tooOldOfferDismissed: "",
        lastBackendPort: 8765,
        pagePreferenceKeys: ["psyneuview.openMenu.sectionOrder", "psynewview_ui_prefs"],
        updateCheck: .init(lastCheck: date, automatic: true, interval: 86_400))

    func testEverySettingHasALineAndAKey() throws {
        let lines = SettingsSnapshot.lines(Self.values, home: Self.home, timeZone: Self.utc)
        for expected in [
            "PsyNeuView runs from: the included PsyNeuView",
            "PsyNeuView checkout path: ~/Library/Application Support/PsyNeuView/app",
            "PsyNeuView branch: devel",
            "Recent checkouts: ~/code/PsyNeuView, ~/old/PsyNeuView",
            "Auto-restart: on",
            "Launch at login: off",
            "Developer mode: on",
            "PsyNeuLink source: github",
            "PsyNeuLink branch: devel",
            "PsyNeuLink repo: default (PrincetonUniversity/PsyNeuLink)",
            "PsyNeuLink local checkout: none",
            "PsyNeuLink update offers: shown",
            "Send reports with: ask",
            "Send reports to: default (\(ReportDefaults.contactEmail))",
            "Last move to the included PsyNeuView: 2026-10-05 09:12: moved to PsyNeuView 0.5.9",
            "Too-old offer dismissed for: nothing",
            "Included PsyNeuView at last launch: not recorded",
            "Older checkout kept over: nothing",
            "Last backend port: 8765",
            "Page preferences kept by the app: 2 (psyneuview.openMenu.sectionOrder, psynewview_ui_prefs)",
            "App update checks: automatic every 24 h, last checked 2026-10-06 14:03",
        ] {
            XCTAssertTrue(lines.contains(expected), "no line \(expected) in \(lines)")
        }
        XCTAssertEqual(lines.count, 21, "one line per setting")

        let d = SettingsSnapshot.dictionary(Self.values, home: Self.home, timeZone: Self.utc)
        XCTAssertEqual(Set(d.keys), [
            "repoPath", "useBundledApp", "branch", "autoRestart", "launchAtLogin", "developerMode",
            "pnlSource", "pnlBranch", "pnlRepo", "pnlLocalPath", "pnlUpdateOffersMuted", "recentCheckouts",
            "reportSendWith", "reportSendTo", "lastMoveOutcome", "tooOldOfferDismissed",
            "includedVersionSeen", "olderCheckoutKeptFor", "lastBackendPort",
            "pagePreferences", "appUpdateCheck",
        ])
        XCTAssertEqual(d["repoPath"] as? String, "~/Library/Application Support/PsyNeuView/app")
        XCTAssertEqual(d["recentCheckouts"] as? [String], ["~/code/PsyNeuView", "~/old/PsyNeuView"])
        XCTAssertEqual(d["lastBackendPort"] as? Int, 8765)
        let pagePrefs = try XCTUnwrap(d["pagePreferences"] as? [String: Any])
        XCTAssertEqual(pagePrefs["count"] as? Int, 2)
        let update = try XCTUnwrap(d["appUpdateCheck"] as? [String: Any])
        XCTAssertEqual(update["lastCheck"] as? String, "2026-10-06 14:03")
        XCTAssertEqual(update["automatic"] as? Bool, true)
        // It's JSON.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: d))
    }

    func testEmptyAndMissingSettingsAreSaidPlainly() throws {
        var v = Self.values
        v.repoPath = nil
        v.useBundledApp = false
        v.recentCheckouts = []
        v.lastMoveOutcome = ""
        v.lastBackendPort = nil
        v.pagePreferenceKeys = []
        v.updateCheck = nil
        let lines = SettingsSnapshot.lines(v, home: Self.home, timeZone: Self.utc)
        for expected in [
            "PsyNeuView runs from: a checkout",
            "PsyNeuView checkout path: none",
            "Recent checkouts: none",
            "Last move to the included PsyNeuView: none tried",
            "Last backend port: none remembered",
            "Page preferences kept by the app: none",
            "App update checks: not available",
        ] {
            XCTAssertTrue(lines.contains(expected), "no line \(expected)")
        }
        let d = SettingsSnapshot.dictionary(v, home: Self.home, timeZone: Self.utc)
        XCTAssertTrue(d["repoPath"] is NSNull)
        XCTAssertTrue(d["lastBackendPort"] is NSNull)
        XCTAssertTrue(d["appUpdateCheck"] is NSNull)
        XCTAssertEqual(SettingsSnapshot.updateCheckDescription(
            .init(lastCheck: nil, automatic: false, interval: nil), timeZone: Self.utc),
            "manual only, last checked never")
    }

    /// Scope (#208): nothing personal, no tokens. A custom "Send to" is an
    /// address, so it is reported as custom and never quoted; a token that
    /// got into a repo name or a path is removed; home is `~`.
    func testNothingPersonalOrSecretGetsThrough() throws {
        var v = Self.values
        v.reportSendTo = "someone@example.org"
        v.pnlRepo = "https://x-access-token:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/me/PsyNeuLink"
        v.pnlLocalPath = "/Users/someone/PsyNeuLink?token=topsecret"
        v.recentCheckouts = ["/Users/someone/checkout"]
        v.tooOldOfferDismissed = "/Users/someone/app:0.5.6"
        let lines = SettingsSnapshot.lines(v, home: Self.home, timeZone: Self.utc).joined(separator: "\n")
        let json = try JSONSerialization.data(
            withJSONObject: SettingsSnapshot.dictionary(v, home: Self.home, timeZone: Self.utc),
            options: [.withoutEscapingSlashes])
        let text = String(decoding: json, as: UTF8.self)
        for output in [lines, text] {
            XCTAssertFalse(output.contains("someone@example.org"), "the address is personal")
            XCTAssertTrue(output.contains("a custom address (not included)"))
            XCTAssertFalse(output.contains("ghp_abcdefghij"))
            XCTAssertFalse(output.contains("topsecret"))
            XCTAssertTrue(output.contains("[REDACTED]"))
            XCTAssertFalse(output.contains("/Users/someone"), "home is ~ in \(output)")
            XCTAssertTrue(output.contains("~/checkout"))
        }
        XCTAssertEqual(SettingsSnapshot.sendToDescription(""), "default (\(ReportDefaults.contactEmail))")
        XCTAssertEqual(SettingsSnapshot.sendToDescription(ReportDefaults.contactEmail.uppercased()),
                       "default (\(ReportDefaults.contactEmail))")
    }

    /// The section lands in report.md and diagnostics.json, and goes when
    /// unticked.
    func testTheReportHasASettingsSection() throws {
        var r = ReportSamples.request()
        r.settings = Self.values
        XCTAssertTrue(ProblemReport.offered(r).contains(.settings))
        let files = ProblemReport.build(r, home: Self.home, timeZone: Self.utc)
        XCTAssertTrue(files.markdown.contains("## Settings\n\n- PsyNeuView runs from: the included PsyNeuView\n"))
        XCTAssertTrue(files.markdown.contains("- Developer mode: on"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: files.diagnostics) as? [String: Any])
        let settings = try XCTUnwrap(json["settings"] as? [String: Any])
        XCTAssertEqual(settings["developerMode"] as? Bool, true)
        XCTAssertEqual(settings["branch"] as? String, "devel")
        XCTAssertEqual(ProblemReport.preview(.settings, of: r, home: Self.home, timeZone: Self.utc)
            .components(separatedBy: "\n").count, 19)

        r.included.remove(.settings)
        let without = ProblemReport.build(r, home: Self.home, timeZone: Self.utc)
        XCTAssertFalse(without.markdown.contains("## Settings"))
        XCTAssertTrue(without.markdown.contains("Left out by the sender: Every app setting (no tokens or addresses)."))
        let withoutJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: without.diagnostics) as? [String: Any])
        XCTAssertNil(withoutJSON["settings"])
        XCTAssertEqual(withoutJSON["omitted"] as? [String], ["settings"])
    }
}
