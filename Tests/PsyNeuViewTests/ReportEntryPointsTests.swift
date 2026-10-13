import Foundation
import XCTest
@testable import PsyNeuView

/// Help ▸ Report a Problem…, the Logs window's button and the failed starting
/// window's button all open the same screen (#202), and that screen is in the
/// Logs window, so the native-window allowlist (PsyNeuView-archive#1279) is unchanged.
///
/// A text check over the app's own source, like NativeWindowPolicyTests: the
/// wiring lives in AppDelegate, which can't be run without the app.
final class ReportEntryPointsTests: XCTestCase {

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PsyNeuView")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheHelpMenuOpensTheReport() throws {
        let app = try source("AppDelegate.swift")
        XCTAssertTrue(app.contains(#"NSMenu(title: "Help")"#), "there's no Help menu")
        XCTAssertTrue(app.contains(#"title: "Report a Problem…", action: #selector(showReportProblem)"#))
        XCTAssertTrue(app.contains("NSApp.helpMenu = helpMenu"))
    }

    func testTheLogsWindowAndTheFailedStartOpenTheSameScreen() throws {
        let app = try source("AppDelegate.swift")
        // The Logs window gets the report and its button opens it the same way.
        XCTAssertTrue(app.contains("report: problemReport,"))
        XCTAssertTrue(app.contains("onReportProblem: { [weak self] in self?.showReportProblem() }"))
        // The failed starting window offers it.
        XCTAssertTrue(app.contains("onReport: { [weak self] in self?.showReportProblem() }"))

        let logs = try source("Views/LogWindowView.swift")
        XCTAssertTrue(logs.contains(#"Button("Report a Problem…", action: onReportProblem)"#))
        XCTAssertTrue(logs.contains("ReportProblemView(model: report)"))

        let starting = try source("Views/StartingView.swift")
        XCTAssertTrue(starting.contains(#"Button("Report a Problem…", action: onReport)"#))
    }

    func testOpeningShowsTheScreenInTheLogsWindow() throws {
        let app = try source("AppDelegate.swift")
        let body = try XCTUnwrap(app.range(of: "@objc func showReportProblem() {"))
        let rest = app[body.upperBound...].prefix(200)
        XCTAssertTrue(rest.contains("problemReport.open()"))
        XCTAssertTrue(rest.contains("showLogWindow()"))
    }

    func testTheReportScreenMakesNoWindowOfItsOwn() throws {
        for file in ["Views/ReportProblemView.swift", "Models/ProblemReportModel.swift"] {
            let text = try source(file)
            for pattern in ["NSWindow(", "NSPanel(", "NSWindowController(", "WindowGroup"] {
                XCTAssertFalse(text.contains(pattern), "\(file) makes a window (\(pattern))")
            }
        }
    }

    @MainActor
    func testOpeningKeepsADraftButStartsAfreshAfterSaving() {
        let model = ProblemReportModel()
        model.captureAppWindow = { done in done(nil) }
        model.open()
        XCTAssertTrue(model.isOpen)
        XCTAssertNotNil(model.screenshotNote, "no app window: no screenshot, and it says so")
        model.whatHappened = "draft"
        model.close()
        model.open()
        XCTAssertEqual(model.whatHappened, "draft")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReportModel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.destination = { dir }
        model.revealInFinder = false
        model.save()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.saved?.folder.deletingLastPathComponent().path, dir.path)
        XCTAssertTrue(model.saved?.folder.lastPathComponent.hasPrefix("PNV-debugging-") ?? false)

        model.close()
        model.open()
        XCTAssertNil(model.saved)
        XCTAssertEqual(model.whatHappened, "")
    }
}
