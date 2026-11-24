import XCTest
@testable import PsyNeuView

/// uv's package list is one row in the Logs window and every line in the
/// launch log (#75).
final class PackageListSummaryTests: XCTestCase {

    func testRecognisesUvPackageLines() {
        XCTAssertEqual(PackageListSummary.change(in: " + wcwidth==0.2.13"), "+")
        XCTAssertEqual(PackageListSummary.change(in: "+ numpy==2.1.0"), "+")
        XCTAssertEqual(PackageListSummary.change(in: " - numpy==2.0.0"), "-")
        XCTAssertEqual(PackageListSummary.change(in: " ~ psyneulink==0.19.1.0 (from file:///tmp/pnl)"), "~")
        XCTAssertEqual(PackageListSummary.change(in: " + uvicorn[standard]==0.30.0"), "+")
        XCTAssertEqual(PackageListSummary.change(in: " + psyneulink @ git+https://github.com/x/y@devel"), "+")
    }

    func testLeavesOtherLinesAlone() {
        for line in ["Installed 214 packages in 3.2s", "Resolved 214 packages", "+ ", "+",
                     "- not a package", "+ name==", "--upgrade", "+=+", "  ✓ Virtual environment created"] {
            XCTAssertNil(PackageListSummary.change(in: line), line)
        }
    }

    func testTheRowSaysWhatChanged() {
        var summary = PackageListSummary()
        XCTAssertTrue(summary.absorb(" + a==1"))
        XCTAssertEqual(summary.text, "Installed 1 package (each one is in the launch log)")
        XCTAssertTrue(summary.absorb(" + b==1"))
        XCTAssertTrue(summary.absorb(" ~ c==1"))
        XCTAssertTrue(summary.absorb(" - d==0"))
        XCTAssertFalse(summary.absorb("Done"))
        XCTAssertEqual(summary.text, "Installed 3 packages, removed 1 (each one is in the launch log)")
        var removedOnly = PackageListSummary()
        _ = removedOnly.absorb(" - a==1")
        _ = removedOnly.absorb(" - b==1")
        XCTAssertEqual(removedOnly.text, "Removed 2 packages (each one is in the launch log)")
    }
}

@MainActor
final class LogCollectorPackageListTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnv-logcollector-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTwoHundredPackageLinesAreOneRowButAllStayInTheLaunchLog() {
        let state = AppState()
        let collector = LogCollector(appState: state)
        let writer = LaunchLogWriter(directory: folder, appVersion: "test")
        collector.launchLog = writer

        collector.add("Resolved 200 packages in 1.1s\n", source: .installer)
        // As the line reader passes them on: one line per call.
        for i in 0..<200 { collector.add(" + package\(i)==1.0.\(i)\n", source: .installer) }
        collector.add("  ✓ Python dependencies installed\n", source: .installer)

        XCTAssertEqual(state.logs.map(\.text), [
            "Resolved 200 packages in 1.1s",
            "Installed 200 packages (each one is in the launch log)",
            "✓ Python dependencies installed",
        ])
        XCTAssertTrue(state.logs.allSatisfy { $0.source == .installer })

        let saved = writer.currentLines()
        XCTAssertEqual(saved.filter { $0.contains("[Installer] + package") }.count, 200)
        XCTAssertTrue(saved.contains { $0.hasSuffix("[Installer] + package199==1.0.199") })
    }

    func testAnotherLineEndsTheRunAndALaterListGetsItsOwnRow() {
        let state = AppState()
        let collector = LogCollector(appState: state)
        collector.add(" + a==1\n + b==1\n", source: .installer)
        collector.add("Retrying\n", source: .installer)
        collector.add(" + c==1\n", source: .installer)
        XCTAssertEqual(state.logs.map(\.text), [
            "Installed 2 packages (each one is in the launch log)",
            "Retrying",
            "Installed 1 package (each one is in the launch log)",
        ])
    }

    func testClearingTheWindowMidListStartsAFreshRow() {
        let state = AppState()
        let collector = LogCollector(appState: state)
        collector.add(" + a==1\n", source: .installer)
        state.clearLogs()
        collector.add(" + b==1\n", source: .installer)
        XCTAssertEqual(state.logs.map(\.text), ["Installed 2 packages (each one is in the launch log)"])
    }
}
