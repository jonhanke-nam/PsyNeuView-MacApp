import Foundation
import XCTest
@testable import PsyNeuView

/// `timeline.txt` (PsyNeuView#177): the page's UTC lines and the launch
/// log's local lines merged in time order in one local format, the health
/// check left out, a traceback's lines kept with their first line, and
/// the file still readable with no server lines.
final class ReportTimelineTests: XCTestCase {

    static let newYork = TimeZone(identifier: "America/New_York")!

    /// What a page built for PsyNeuView#177 answers, in UTC: the #175 case.
    static let page: [Any] = [
        ["t": "2026-11-03T14:15:04.850Z", "source": "action", "text": "Open menu opened"] as [String: Any],
        ["t": "2026-11-03T14:15:04.855Z", "source": "wait", "text": "start · GET /api/psyneulink-examples/status · from: Open menu opened"] as [String: Any],
        ["t": "2026-11-03T14:15:20.000Z", "source": "action", "text": "Open › Cohen Huston1994"] as [String: Any],
        ["t": "2026-11-03T14:15:20.100Z", "source": "wait", "text": "start · POST /api/model/load · likely from: Open › Cohen Huston1994"] as [String: Any],
        ["t": "2026-11-03T14:15:21.100Z", "source": "wait", "text": "stop · POST /api/model/load · 1.000 s · ok"] as [String: Any],
        ["t": "2026-11-03T14:15:21.200Z", "source": "error", "text": "Error shown: Example model failed to load · likely from: Open › Cohen Huston1994"] as [String: Any],
        ["t": "2026-11-03T14:16:35.000Z", "source": "wait", "text": "stop · GET /api/psyneulink-examples/status · 90.145 s · ok"] as [String: Any],
    ]

    /// The same minutes in the launch log, in New York time (UTC-5 in November).
    static let log = [
        "[2026-11-03 09:14:19.779] [Backend] INFO:     Uvicorn running on http://127.0.0.1:8000",
        "[2026-11-03 09:15:04.900] [Backend] INFO:     127.0.0.1:50000 - \"GET /health HTTP/1.1\" 200 OK",
        "[2026-11-03 09:15:05.487] [Backend] [perf] warm worker introspect: 0.49s",
        "[2026-11-03 09:15:21.150] [Backend] [error] Traceback (most recent call last):",
        "  File \"/Users/someone/code/model.py\", line 3, in <module>",
        "ValueError: no such mechanism",
        "[2026-11-03 09:15:30.000] [Backend] INFO:     127.0.0.1:50001 - \"GET /health HTTP/1.1\" 200 OK",
        "    (a line after the health check, which goes with it)",
        "[2026-11-03 09:16:34.990] [System] still waiting for the examples status",
    ]

    static func entries(_ page: [Any]) -> [PageDiagnostics.TimelineEntry] {
        PageDiagnostics.timelineEntries(page)
    }

    func testTheMergeIsInTimeOrderInOneLocalFormatWithTheHealthCheckLeftOut() {
        let text = ReportTimeline.text(page: Self.entries(Self.page), log: Self.log,
                                       timeZone: Self.newYork, home: "/Users/someone")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.last, "", "ends with a newline")
        XCTAssertEqual(Array(lines.dropLast()), [
            "# PsyNeuView timeline: what the user did, what the app did, errors, waits and the server log, in time order.",
            "# Times are local to this Mac: America/New_York (UTC-05:00). Sources: action · event · error · message · wait · page · server.",
            "# Routine server lines (the health check) are left out; logs.txt has every line.",
            "2026-11-03 09:14:19.779  server   Backend · INFO:     Uvicorn running on http://127.0.0.1:8000",
            "2026-11-03 09:15:04.850  action   Open menu opened",
            "2026-11-03 09:15:04.855  wait     start · GET /api/psyneulink-examples/status · from: Open menu opened",
            "2026-11-03 09:15:05.487  server   Backend · [perf] warm worker introspect: 0.49s",
            "2026-11-03 09:15:20.000  action   Open › Cohen Huston1994",
            "2026-11-03 09:15:20.100  wait     start · POST /api/model/load · likely from: Open › Cohen Huston1994",
            "2026-11-03 09:15:21.100  wait     stop · POST /api/model/load · 1.000 s · ok",
            "2026-11-03 09:15:21.150  server   Backend [error] · Traceback (most recent call last):",
            // The rest of the traceback: indented, with the first line's time.
            "2026-11-03 09:15:21.150  server       File \"~/code/model.py\", line 3, in <module>",
            "2026-11-03 09:15:21.150  server     ValueError: no such mechanism",
            "2026-11-03 09:15:21.200  error    Error shown: Example model failed to load · likely from: Open › Cohen Huston1994",
            "2026-11-03 09:16:34.990  server   System · still waiting for the examples status",
            "2026-11-03 09:16:35.000  wait     stop · GET /api/psyneulink-examples/status · 90.145 s · ok",
        ])
    }

    func testAtTheSameInstantThePageComesFirstAndEachKeepsItsOrder() {
        let page = Self.entries([
            ["t": "2026-11-03T14:15:04.850Z", "source": "action", "text": "first"] as [String: Any],
            ["t": "2026-11-03T14:15:04.850Z", "source": "event", "text": "second"] as [String: Any],
        ] as [Any])
        let log = ["[2026-11-03 09:15:04.850] [Backend] third", "[2026-11-03 09:15:04.850] [Backend] fourth"]
        let merged = ReportTimeline.merged(page: ReportTimeline.pageLines(page),
                                           server: ReportTimeline.serverLines(log, timeZone: Self.newYork))
        XCTAssertEqual(merged.map { $0.text }, ["first", "second", "Backend · third", "Backend · fourth"])
    }

    func testWithNoServerLinesThePagesPartStillReads() {
        let text = ReportTimeline.text(page: Self.entries(Self.page), log: [], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(text.contains("# No server log lines: the log had nothing but routine lines."))
        XCTAssertTrue(text.contains("2026-11-03 14:15:04.850  action   Open menu opened\n"))
        XCTAssertFalse(text.contains("  server   "))
        // And a log of nothing but the health check is the same as none.
        let routine = ReportTimeline.text(page: Self.entries(Self.page), log: [Self.log[1]], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(routine.contains("# No server log lines"))
    }

    /// The sender unticked logs.txt: the log goes nowhere in the report, so
    /// not into the timeline either, and the file says why it has none.
    func testWhenTheLogIsLeftOutOfTheReportTheTimelineHasNoServerLines() {
        let text = ReportTimeline.text(page: Self.entries(Self.page), log: Self.log, logIncluded: false,
                                       timeZone: TimeZone(identifier: "UTC")!, home: "/Users/someone")
        XCTAssertTrue(text.contains("# No server log lines: the sender left this launch's log out of the report."), text)
        XCTAssertFalse(text.contains("  server   "), text)
        XCTAssertFalse(text.contains("Uvicorn"), text)
        XCTAssertTrue(text.contains("2026-11-03 14:15:04.850  action   Open menu opened\n"))
    }

    func testWithNoPageLinesTheFileSaysSo() {
        let text = ReportTimeline.text(page: [], log: [Self.log[0]], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(text.contains("# No lines from PsyNeuView's page: it didn't provide a timeline (older version or not loaded)."))
        // Read and written in the same zone, the log's time comes out as it went in.
        XCTAssertTrue(text.contains("2026-11-03 09:14:19.779  server   Backend · INFO:"), text)
    }

    func testThePagesTimesAreReadAsISOOrEpochAndBadOnesLeftOut() {
        let entries: [PageDiagnostics.TimelineEntry] = Self.entries([
            ["t": "2026-11-03T14:15:04.850Z", "source": "action", "text": "iso with fractions"] as [String: Any],
            ["t": "2026-11-03T14:15:05Z", "source": "action", "text": "iso without"] as [String: Any],
            ["time": 1_793_715_306_500, "source": "action", "text": "epoch milliseconds, under time"] as [String: Any],
            ["t": "yesterday", "source": "action", "text": "unreadable"] as [String: Any],
            ["source": "action", "text": "no time"] as [String: Any],
            "not an object",
        ] as [Any])
        XCTAssertEqual(entries.map { $0.text }, ["iso with fractions", "iso without", "epoch milliseconds, under time"])
        XCTAssertEqual(entries.map { $0.time.timeIntervalSince1970 }, [1_793_715_304.85, 1_793_715_305, 1_793_715_306.5])
    }

    func testTheLatestLinesAreKeptWhenThereAreTooMany() {
        let many: [Any] = (1...(ReportTimeline.maxLines + 3)).map {
            ["t": "2026-11-03T14:15:04.850Z", "source": "event", "text": "\($0)"] as [String: Any]
        }
        let text = ReportTimeline.text(page: Self.entries(many), log: [], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(text.contains("[… the earliest 3 lines were left out]\n2026-11-03 14:15:04.850  event    4\n"))
        XCTAssertTrue(text.hasSuffix("event    \(ReportTimeline.maxLines + 3)\n"))
    }

    func testRoutineLines() {
        XCTAssertTrue(ReportTimeline.isRoutine("Backend · INFO:     127.0.0.1:50000 - \"GET /health HTTP/1.1\" 200 OK"))
        XCTAssertFalse(ReportTimeline.isRoutine("Backend · INFO:     127.0.0.1:50000 - \"GET /api/healthy-model HTTP/1.1\" 200 OK"))
        XCTAssertFalse(ReportTimeline.isRoutine("Backend · [perf] warm worker introspect: 0.49s"))
    }
}
