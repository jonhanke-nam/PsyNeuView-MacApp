import Foundation
import XCTest
@testable import PsyNeuView

/// The Mac app is a thin wrapper around PsyNeuView's React app
/// (jonhanke-nam/PsyNeuView-archive#1279, PsyNeuView-MacApp#200).
///
/// UI that can live in React lives in React, Settings included. The app adds
/// only what React can't do, through bridges (`pnvFile`, `pnvSettings`) and
/// menu items that route into the React UI. A native window is an exception
/// that needs a concrete reason.
///
/// This reads the app's own source, which CI checks out alongside the tests.
/// It is a text check, not a proof: it finds windows made the ways this app
/// makes them (`NSWindow(`, `NSPanel(`, `NSWindowController(`, SwiftUI
/// `Window`/`WindowGroup`/`Settings` scenes). System panels and alerts
/// (`NSOpenPanel`, `NSSavePanel`, `NSAlert`) are not windows of our own.
final class NativeWindowPolicyTests: XCTestCase {

    /// The native windows the app may have, by "File.swift › function that
    /// makes it", each with its reason.
    ///
    /// To add one: put it here with a reason as concrete as these — why it
    /// must exist before React does, or when React can't run — and write the
    /// same reason next to the code that makes it. "It was quicker" is not a
    /// reason; a settings window never is (that's PsyNeuView's Settings).
    static let allowedWindows: [String: String] = [
        "AppDelegate.swift › openAppWindow":
            "The app window itself: it hosts PsyNeuView's React UI.",
        "AppDelegate.swift › showSetupWizard":
            "Setup Wizard: runs on first launch, before any PsyNeuView is installed.",
        "AppDelegate.swift › showStartingWindow":
            "Starting window and its progress checklist: shown before the server, and so React, is up.",
        "AppDelegate.swift › showLogWindow":
            "Logs: must work when the server can't start, to show why.",
        "AboutWindow.swift › show":
            "About: shows versions even when the server is down.",
    ]

    private static var sourcesDirectory: URL {
        // Tests/PsyNeuViewTests/<this file> -> Sources/PsyNeuView
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PsyNeuView")
    }

    private func swiftSources() throws -> [(name: String, lines: [String])] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil))
        var files: [(String, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append((url.lastPathComponent, text.components(separatedBy: "\n")))
        }
        XCTAssertFalse(files.isEmpty, "found no sources at \(Self.sourcesDirectory.path)")
        return files
    }

    private static let windowPattern = try! NSRegularExpression(
        pattern: #"\b(NSWindow|NSPanel|NSWindowController)\(|\bWindowGroup\b|\bWindow\(\s*"|^\s*Settings\s*\{"#)
    private static let funcPattern = try! NSRegularExpression(pattern: #"\bfunc\s+(\w+)"#)

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    /// Every place a window is made, as "File.swift › function".
    private func windowSites() throws -> [String] {
        var sites: [String] = []
        for (name, lines) in try swiftSources() {
            var function = "(top level)"
            for line in lines {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                if let m = Self.matches(Self.funcPattern, line), let r = Range(m.range(at: 1), in: line) {
                    function = String(line[r])
                }
                if Self.matches(Self.windowPattern, line) != nil {
                    sites.append("\(name) › \(function)")
                }
            }
        }
        return sites
    }

    func testEveryNativeWindowIsAnAllowedException() throws {
        let sites = try windowSites()
        for site in sites {
            XCTAssertNotNil(
                Self.allowedWindows[site],
                "\(site) makes a native window that isn't on the allowed list. "
                + "UI belongs in PsyNeuView's React app (PsyNeuView-archive#1279); if this "
                + "window truly can't, add it to allowedWindows with its reason.")
        }
        // The list stays honest: nothing on it that no longer exists.
        for allowed in Self.allowedWindows.keys {
            XCTAssertTrue(sites.contains(allowed), "\(allowed) is allowed but no longer makes a window")
        }
    }

    func testThereIsNoNativeSettingsWindow() throws {
        let forbidden = try NSRegularExpression(
            pattern: #"\b(struct|class)\s+(PreferencesView|SettingsView|SettingsWindow\w*)\b|"PsyNeuView — (Preferences|Settings)""#)
        for (name, lines) in try swiftSources() {
            for (i, line) in lines.enumerated() where Self.matches(forbidden, line) != nil {
                XCTFail("\(name):\(i + 1) brings back a native Settings window; Settings is PsyNeuView's (#200)")
            }
        }
    }

    /// The bridge's Mac app keys are the inventory's `settings:mac-app`
    /// entries. This is a copy of those `bridge_key`s from
    /// jonhanke-nam/PsyNeuView docs/settings-inventory.yaml — that repo isn't
    /// checked out here — so change both together.
    static let inventoryMacAppKeys: Set<String> = [
        "install", "autoRestart", "launchAtLogin", "reportSendWith", "reportSendTo",
    ]

    func testBridgeKeysMatchTheInventory() {
        XCTAssertEqual(Set(SettingsBridge.macAppKeys), Self.inventoryMacAppKeys)
        XCTAssertEqual(SettingsBridge.macAppKeys.count, Self.inventoryMacAppKeys.count, "a key is listed twice")
        // Developer mode is PsyNeuView's setting; the bridge only carries it.
        XCTAssertTrue(Set(SettingsBridge.pageOwnedKeys).isDisjoint(with: Self.inventoryMacAppKeys))
    }
}
