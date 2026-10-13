import Foundation
import XCTest
@testable import PsyNeuView

/// Saving a problem report (#202), into a temporary folder rather than
/// Downloads.
final class ReportWriterTests: XCTestCase {

    private var destination: URL!

    override func setUp() {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportWriterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: destination)
    }

    private let files = ProblemReport.Files(
        markdown: "# PsyNeuView problem report\n",
        diagnostics: Data("{}".utf8),
        logs: "a line\n")
    private let shot = ReportWriter.Screenshot(name: "screenshot-1.png", png: Data([0x89, 0x50, 0x4E, 0x47]))

    func testSavesTheFolderAndAZipBesideIt() throws {
        let saved = try ReportWriter.save(
            reference: "PNV-debugging-2026-10-06_14-03-22", files: files,
            screenshots: [shot], into: destination)
        XCTAssertEqual(saved.folder.lastPathComponent, "PNV-debugging-2026-10-06_14-03-22")
        XCTAssertEqual(saved.files.map(\.lastPathComponent),
                       ["report.md", "screenshot-1.png", "logs.txt", "diagnostics.json"])
        XCTAssertEqual(try String(contentsOf: saved.folder.appendingPathComponent("report.md"), encoding: .utf8),
                       "# PsyNeuView problem report\n")
        XCTAssertEqual(try Data(contentsOf: saved.folder.appendingPathComponent("screenshot-1.png")), shot.png)

        let zip = try XCTUnwrap(saved.zip)
        XCTAssertEqual(zip.lastPathComponent, "PNV-debugging-2026-10-06_14-03-22.zip")
        XCTAssertEqual(zip.deletingLastPathComponent().path, destination.path)
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 0)
    }

    /// The files #208 added, each written only when there is one.
    func testThePreviousLaunchAndPageFilesAreWrittenWhenPresent() throws {
        var full = files
        full.previousLogs = "earlier\n"
        full.pageState = "{\n  \"a\" : 1\n}\n"
        full.pageActivity = "t · kind · text\n"
        let saved = try ReportWriter.save(reference: "R", files: full, screenshots: [], into: destination, zip: false)
        XCTAssertEqual(saved.files.map(\.lastPathComponent),
                       ["report.md", "logs.txt", "logs-previous-launch.txt", "page-state.json", "activity.txt", "diagnostics.json"])
        XCTAssertEqual(saved.files.map(\.lastPathComponent), full.attachments(screenshots: []),
                       "the folder holds exactly what the report lists")
        XCTAssertEqual(try String(contentsOf: saved.folder.appendingPathComponent("activity.txt"), encoding: .utf8),
                       "t · kind · text\n")
        XCTAssertEqual(try String(contentsOf: saved.folder.appendingPathComponent("logs-previous-launch.txt"), encoding: .utf8),
                       "earlier\n")
    }

    func testLeftOutLogsAreNotWritten() throws {
        var noLogs = files
        noLogs.logs = nil
        let saved = try ReportWriter.save(
            reference: "R", files: noLogs, screenshots: [], into: destination, zip: false)
        XCTAssertEqual(saved.files.map(\.lastPathComponent), ["report.md", "diagnostics.json"])
        XCTAssertNil(saved.zip)
    }

    func testTwoReportsInOneSecondDontCollide() throws {
        let a = try ReportWriter.save(reference: "R", files: files, screenshots: [], into: destination)
        let b = try ReportWriter.save(reference: "R", files: files, screenshots: [], into: destination)
        XCTAssertEqual(a.folder.lastPathComponent, "R")
        XCTAssertEqual(b.folder.lastPathComponent, "R-2")
        XCTAssertEqual(b.zip?.lastPathComponent, "R-2.zip")
    }
}
