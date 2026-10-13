import Foundation
import XCTest
@testable import PsyNeuView

/// Each launch's log file (#208): names, which files are kept, the line
/// format and the size cap, and the writer against a temporary folder.
final class LaunchLogTests: XCTestCase {

    static let utc = TimeZone(identifier: "UTC")!
    // 2026-10-09 14:03:22 UTC
    static let date = Date(timeIntervalSince1970: 1_791_554_602)

    // MARK: Names and rotation

    func testTheFileNameHasTheDateAndNoColons() {
        let name = LaunchLog.fileName(for: Self.date, timeZone: Self.utc)
        XCTAssertEqual(name, "launch-2026-10-09_14-03-22.log")
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(LaunchLog.isLaunchLog(name))
        XCTAssertFalse(LaunchLog.isLaunchLog("launch-.log"))
        XCTAssertFalse(LaunchLog.isLaunchLog("other.log"))
    }

    func testOnlyTheLastFiveLaunchesAreKept() {
        let names = (1...7).map { "launch-2026-10-0\($0)_10-00-00.log" } + ["notes.txt", ".DS_Store"]
        // Room for the new one: of 7, keep the newest 4 and drop 3.
        XCTAssertEqual(LaunchLog.namesToRemove(existing: names.shuffled(), keep: 5),
                       ["launch-2026-10-01_10-00-00.log", "launch-2026-10-02_10-00-00.log",
                        "launch-2026-10-03_10-00-00.log"])
        XCTAssertEqual(LaunchLog.namesToRemove(existing: Array(names.prefix(3)), keep: 5), [])
        XCTAssertEqual(LaunchLog.namesToRemove(existing: [], keep: 5), [])
        XCTAssertEqual(LaunchLog.previous(in: names.shuffled()), "launch-2026-10-07_10-00-00.log")
        XCTAssertNil(LaunchLog.previous(in: ["notes.txt"]))
    }

    // MARK: Lines

    func testALineHasTheFullDateSourceAndErrorMark() {
        XCTAssertEqual(
            LaunchLog.formatLine(date: Self.date, source: .backend, text: "pip failed", isError: true, timeZone: Self.utc),
            "[2026-10-09 14:03:22.000] [Backend] [error] pip failed")
        XCTAssertEqual(
            LaunchLog.formatLine(date: Self.date, source: .system, text: "started", isError: false, timeZone: Self.utc),
            "[2026-10-09 14:03:22.000] [System] started")
        XCTAssertTrue(LaunchLog.header(appVersion: "0.5.19", date: Self.date, timeZone: Self.utc)
            .contains("PsyNeuView app 0.5.19 launched"))
    }

    // MARK: The size cap

    func testAFileUnderTheCapIsLeftAlone() {
        let lines = ["a", "b", "c"]
        XCTAssertEqual(LaunchLog.trim(lines, maxBytes: 100, targetBytes: 75), LaunchLog.Trimmed(lines: lines, dropped: 0))
    }

    func testOverTheCapTheEarliestLinesGoFirstWithANote() {
        // 40 lines of 10 bytes each (with the newline): 400 bytes.
        let lines = (1...40).map { String(format: "line %04d", $0) }
        let trimmed = LaunchLog.trim(lines, maxBytes: 300, targetBytes: 250)
        XCTAssertTrue(trimmed.lines.first!.hasPrefix(LaunchLog.notePrefix))
        XCTAssertTrue(trimmed.lines.first!.contains("dropped to keep this file under"))
        XCTAssertEqual(trimmed.lines.last, "line 0040")
        XCTAssertGreaterThan(trimmed.dropped, 0)
        XCTAssertEqual(trimmed.lines.count, lines.count - trimmed.dropped + 1)
        XCTAssertEqual(trimmed.lines[1], String(format: "line %04d", trimmed.dropped + 1))
        XCTAssertLessThanOrEqual(LaunchLog.bytes(of: trimmed.lines), 300)
    }

    func testASecondTrimCountsWhatTheFirstDropped() {
        let first = LaunchLog.trim((1...40).map { String(format: "line %04d", $0) }, maxBytes: 300, targetBytes: 250)
        let more = first.lines + (41...80).map { String(format: "line %04d", $0) }
        let second = LaunchLog.trim(more, droppedBefore: first.dropped, maxBytes: 300, targetBytes: 250)
        XCTAssertGreaterThan(second.dropped, first.dropped)
        XCTAssertEqual(second.lines.filter { $0.hasPrefix(LaunchLog.notePrefix) }.count, 1, "one note, at the top")
        XCTAssertEqual(LaunchLog.droppedCount(in: second.lines[0]), second.dropped)
        XCTAssertEqual(second.lines.last, "line 0080")
        // The count survives a reread of the file (no droppedBefore).
        XCTAssertEqual(LaunchLog.trim(second.lines, maxBytes: 300, targetBytes: 250).dropped, second.dropped)
    }

    func testTheNoteReadsPlainly() {
        XCTAssertEqual(LaunchLog.droppedNote(lines: 1_234),
                       "[… the earliest 1,234 lines of this launch were dropped to keep this file under 5 MB]")
        XCTAssertEqual(LaunchLog.droppedCount(in: LaunchLog.droppedNote(lines: 1_234)), 1_234)
        XCTAssertTrue(LaunchLog.droppedNote(lines: 1).contains("1 line of"))
    }

    // MARK: The writer

    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchLogTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheWriterWritesEachLineAsItComesAndReadsItBack() throws {
        let writer = LaunchLogWriter(directory: folder, date: Self.date, appVersion: "0.5.19")
        XCTAssertNil(writer.failure)
        XCTAssertNil(writer.previousFileURL, "a first launch has no previous log")
        writer.append(source: .system, text: "one", isError: false, at: Self.date)
        writer.append(source: .backend, text: "two", isError: true, at: Self.date)
        // On disk already, before anything else happens.
        let onDisk = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("[Backend] [error] two\n"))
        let lines = writer.currentLines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("launched"))
        XCTAssertTrue(lines[1].hasSuffix("[System] one"))
        XCTAssertNil(writer.previousLines())
    }

    func testTheNextLaunchSeesThePreviousLogAndDropsTheOldest() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for day in 1...5 {
            try "old \(day)\n".write(
                to: folder.appendingPathComponent("launch-2026-10-0\(day)_10-00-00.log"),
                atomically: true, encoding: .utf8)
        }
        let writer = LaunchLogWriter(directory: folder, date: Self.date, appVersion: "0.5.19", keep: 5)
        XCTAssertEqual(writer.previousFileURL?.lastPathComponent, "launch-2026-10-05_10-00-00.log")
        XCTAssertEqual(writer.previousLines(), ["old 5"])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, [
            "launch-2026-10-02_10-00-00.log", "launch-2026-10-03_10-00-00.log",
            "launch-2026-10-04_10-00-00.log", "launch-2026-10-05_10-00-00.log",
            writer.fileURL.lastPathComponent,
        ])
    }

    func testTheWriterTrimsTheFileWhenItPassesTheCap() throws {
        let writer = LaunchLogWriter(directory: folder, date: Self.date, appVersion: "0.5.19",
                                     maxBytes: 2_000, targetBytes: 1_500)
        for i in 1...100 {
            writer.append(source: .system, text: String(format: "line %04d", i), isError: false, at: Self.date)
        }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: writer.fileURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 2_000)
        let lines = writer.currentLines()
        XCTAssertTrue(lines[0].hasPrefix(LaunchLog.notePrefix))
        XCTAssertTrue(lines.last!.hasSuffix("line 0100"), "the newest line is kept")
        XCTAssertGreaterThan(writer.dropped, 0)
        XCTAssertEqual(LaunchLog.droppedCount(in: lines[0]), writer.dropped)
        // Writing goes on after the trim.
        writer.append(source: .system, text: "after", isError: false, at: Self.date)
        XCTAssertTrue(writer.currentLines().last!.hasSuffix("after"))
    }
}
