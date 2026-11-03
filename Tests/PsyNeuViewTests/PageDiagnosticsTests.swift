import Foundation
import XCTest
@testable import PsyNeuView

/// PsyNeuView's diagnostics in the report (#208): the page's answer read
/// into page-state.json and activity.txt, and the report going on without
/// them when the page doesn't answer.
final class PageDiagnosticsTests: XCTestCase {

    static let home = ReportSamples.home
    static let utc = ReportSamples.utc

    /// What a page built for PsyNeuView-archive#1287 answers.
    static let answer: [String: Any] = [
        "version": 1,
        "state": [
            "model": ["path": "/Users/someone/models/stroop.py", "unsaved": false] as [String: Any],
            "developerMode": true,
            "panels": ["active": "inspector"],
        ] as [String: Any],
        "activity": [
            ["time": "2026-10-06T14:00:01.000Z", "kind": "menu", "text": "Open ▸ Stroop"],
            ["time": 1_791_295_262_000, "kind": "run", "text": "Run finished: 3 trials"] as [String: Any],
            ["time": "2026-10-06T14:02:00.000Z", "kind": "error", "text": "Couldn't save /Users/someone/x\ntoken=abc"],
            ["kind": "settings"],
            "not an object",
        ] as [Any],
    ]

    /// What a page built for PsyNeuView#177 answers: the same, with the
    /// timeline, the previous launch's saved activity, and the setting.
    static var fullAnswer: [String: Any] {
        var a = answer
        a["timeline"] = [
            ["t": "2026-10-06T14:00:01.000Z", "source": "action", "text": "Open › Stroop"],
            ["t": "2026-10-06T14:00:01.050Z", "source": "wait", "text": "start · POST /api/model/load · from: Open › Stroop"],
            ["t": "2026-10-06T14:00:02.050Z", "source": "wait", "text": "stop · POST /api/model/load · 1.000 s · failed, HTTP 500"],
            ["t": "2026-10-06T14:00:02.100Z", "source": "error", "text": "Error shown: Couldn't load /Users/someone/x · after: POST /api/model/load failed (HTTP 500) · likely from: Open › Stroop"],
        ] as [Any]
        a["previousActivity"] = [
            ["t": "2026-10-06T13:00:01.000Z", "time": "2026-10-06T13:00:01.000Z", "kind": "menu", "text": "Open › Earlier"],
            ["t": "2026-10-06T13:00:02.000Z", "time": "2026-10-06T13:00:02.000Z", "kind": "error", "text": "Model error: before the restart"],
        ] as [Any]
        a["actionLogging"] = false
        return a
    }

    // MARK: Reading the answer

    /// The page's real shape (PsyNeuView#176): `t` and `time` the same ISO
    /// time. An older page wrote only `t`, and every line of activity.txt
    /// began with `?`; either is read now.
    func testAnEntrysTimeIsTimeOrT() {
        let lines = PageDiagnostics.activityLines([
            ["t": "2026-11-03T16:00:17.058Z", "time": "2026-11-03T16:00:17.058Z", "kind": "menu", "text": "Open menu opened"],
            ["t": "2026-11-03T16:00:17.059Z", "kind": "wait", "text": "GET /api/psyneulink-examples · stopped 2026-11-03T16:00:17.088Z · 0.029 s · ok · from: Open menu opened",
             "data": ["label": "GET /api/psyneulink-examples", "durationMs": 29] as [String: Any]] as [String: Any],
            ["t": 1_791_295_262_000, "kind": "run", "text": "Run finished: 3 trials"] as [String: Any],
            ["t": NSNull(), "time": "2026-11-03T16:00:18.000Z", "kind": "menu", "text": "null t, time given"] as [String: Any],
        ])
        XCTAssertEqual(lines, [
            "2026-11-03T16:00:17.058Z · menu · Open menu opened",
            "2026-11-03T16:00:17.059Z · wait · GET /api/psyneulink-examples · stopped 2026-11-03T16:00:17.088Z · 0.029 s · ok · from: Open menu opened",
            "2026-10-06T14:01:02.000Z · run · Run finished: 3 trials",
            "2026-11-03T16:00:18.000Z · menu · null t, time given",
        ])
    }

    /// The timeline, the previous launch's activity and the setting
    /// (PsyNeuView#177) are read; an older page's answer has none, and
    /// offers neither part.
    func testTheTimelineAndThePreviousLaunchAreReadAndAttached() throws {
        let older = try XCTUnwrap(PageDiagnostics.outcome(result: Self.answer, error: nil).provided)
        XCTAssertEqual(older.timeline, [])
        XCTAssertEqual(older.previousActivityLines, [])
        XCTAssertNil(older.actionLogging)
        var r = ReportSamples.request()
        r.page = .provided(older)
        XCTAssertFalse(ProblemReport.offered(r).contains(.timeline))
        XCTAssertFalse(ProblemReport.offered(r).contains(.previousPageActivity))
        XCTAssertNil(ReportSamples.build(r).timeline)

        let provided = try XCTUnwrap(PageDiagnostics.outcome(result: Self.fullAnswer, error: nil).provided)
        XCTAssertEqual(provided.timeline.count, 4)
        XCTAssertEqual(provided.timeline[0], PageDiagnostics.TimelineEntry(
            time: Date(timeIntervalSince1970: 1_791_295_201), source: "action", text: "Open › Stroop"))
        XCTAssertEqual(provided.previousActivityLines, [
            "2026-10-06T13:00:01.000Z · menu · Open › Earlier",
            "2026-10-06T13:00:02.000Z · error · Model error: before the restart",
        ])
        XCTAssertEqual(provided.actionLogging, false)

        r.page = .provided(provided)
        r.logLines = ["[2026-10-06 14:00:01.500] [Backend] [perf] introspect: 0.4s"]
        XCTAssertEqual(ProblemReport.offered(r), [.versions, .startup, .logs, .pageState, .pageActivity,
                                                  .previousPageActivity, .timeline, .system])
        let files = ReportSamples.build(r)
        XCTAssertEqual(files.previousPageActivity, """
        2026-10-06T13:00:01.000Z · menu · Open › Earlier
        2026-10-06T13:00:02.000Z · error · Model error: before the restart

        """)
        let timeline = try XCTUnwrap(files.timeline)
        XCTAssertTrue(timeline.contains("# Times are local to this Mac: UTC (UTC+00:00)."), timeline)
        XCTAssertTrue(timeline.contains("""
        2026-10-06 14:00:01.000  action   Open › Stroop
        2026-10-06 14:00:01.050  wait     start · POST /api/model/load · from: Open › Stroop
        2026-10-06 14:00:01.500  server   Backend · [perf] introspect: 0.4s
        2026-10-06 14:00:02.050  wait     stop · POST /api/model/load · 1.000 s · failed, HTTP 500
        2026-10-06 14:00:02.100  error    Error shown: Couldn't load ~/x · after: POST /api/model/load failed (HTTP 500) · likely from: Open › Stroop

        """), timeline)
        XCTAssertTrue(files.markdown.contains("- activity.txt: PsyNeuView's activity since launch, one line per entry: time · kind · text (action logging was off: what the user did isn't in it)"))
        XCTAssertTrue(files.markdown.contains("- activity-previous-launch.txt: PsyNeuView's activity in the previous launch, from the copy it keeps on this Mac"))
        XCTAssertTrue(files.markdown.contains("- timeline.txt: what the user did, what PsyNeuView did, errors, every wait's start and stop, and the server log, in time order"))
        let json = ReportSamples.diagnostics(files)
        XCTAssertEqual((json["page"] as? [String: Any])?["actionLogging"] as? Bool, false)
        XCTAssertEqual(json["attachments"] as? [String], [
            "report.md", "screenshot-1.png", "logs.txt", "page-state.json", "activity.txt",
            "activity-previous-launch.txt", "timeline.txt", "diagnostics.json",
        ])
        // The View buttons show the same, newest lines first in the usual way.
        XCTAssertTrue(ProblemReport.preview(.timeline, of: r, home: Self.home, timeZone: Self.utc).contains("action   Open › Stroop"))
        XCTAssertTrue(ProblemReport.preview(.previousPageActivity, of: r, home: Self.home).contains("Open › Earlier"))
        // Each can be left out on its own; the timeline is its own part, so
        // leaving the log out doesn't empty it.
        r.included.remove(.logs)
        r.included.remove(.previousPageActivity)
        let fewer = ReportSamples.build(r)
        XCTAssertNil(fewer.logs)
        XCTAssertNil(fewer.previousPageActivity)
        XCTAssertTrue(fewer.timeline!.contains("server   Backend · [perf] introspect: 0.4s"))
        XCTAssertTrue(fewer.markdown.contains("Left out by the sender: This launch's whole log; PsyNeuView's activity in the previous launch."))
    }

    func testAnAnswerBecomesStateJSONAndActivityLines() throws {
        let provided = try XCTUnwrap(PageDiagnostics.outcome(result: Self.answer, error: nil).provided)
        XCTAssertEqual(provided.version, 1)
        XCTAssertEqual(provided.stateJSON, """
        {
          "developerMode" : true,
          "model" : {
            "path" : "/Users/someone/models/stroop.py",
            "unsaved" : false
          },
          "panels" : {
            "active" : "inspector"
          }
        }
        """)
        XCTAssertEqual(provided.activityLines, [
            "2026-10-06T14:00:01.000Z · menu · Open ▸ Stroop",
            "2026-10-06T14:01:02.000Z · run · Run finished: 3 trials",
            "2026-10-06T14:02:00.000Z · error · Couldn't save /Users/someone/x token=abc",
            "? · settings · ?",
            "? · ? · not an object",
        ])
    }

    func testActivityTextIsOneLinePerEntryRedacted() {
        let lines = PageDiagnostics.activityLines(Self.answer["activity"] as! [Any])
        let text = PageDiagnostics.activityText(lines, home: Self.home)
        XCTAssertEqual(text, """
        2026-10-06T14:00:01.000Z · menu · Open ▸ Stroop
        2026-10-06T14:01:02.000Z · run · Run finished: 3 trials
        2026-10-06T14:02:00.000Z · error · Couldn't save ~/x token=[REDACTED]
        ? · settings · ?
        ? · ? · not an object

        """)
        XCTAssertEqual(PageDiagnostics.activityText([], home: Self.home), "(no activity recorded)\n")
    }

    func testTheLatestActivityIsKeptWhenThereIsTooMuch() {
        let many = (1...(PageDiagnostics.maxActivityLines + 5)).map { ["kind": "k", "text": "\($0)"] as Any }
        let lines = PageDiagnostics.activityLines(many)
        XCTAssertEqual(lines.count, PageDiagnostics.maxActivityLines + 1)
        XCTAssertEqual(lines.first, "[… the earliest 5 entries were left out]")
        XCTAssertEqual(lines.last, "? · k · \(PageDiagnostics.maxActivityLines + 5)")
    }

    func testEpochTimesAreReadAsSecondsOrMilliseconds() {
        XCTAssertEqual(PageDiagnostics.isoTime(1_791_295_262), "2026-10-06T14:01:02.000Z")
        XCTAssertEqual(PageDiagnostics.isoTime(1_791_295_262_500), "2026-10-06T14:01:02.500Z")
    }

    func testTheStateIsCapped() {
        let big = ["blob": String(repeating: "x", count: PageDiagnostics.maxStateBytes + 100)]
        let json = PageDiagnostics.stateJSON(big)
        XCTAssertTrue(json.hasSuffix("… [cut at 1024 KB]"))
        XCTAssertLessThanOrEqual(json.utf8.count, PageDiagnostics.maxStateBytes + 40)
    }

    /// The "page didn't answer" paths: null (older page, no function), an
    /// error, the wrong shape, no window, and no answer in time.
    func testWhenThePageDoesntAnswerTheReasonIsSaid() {
        let note = PageDiagnostics.notProvidedNote
        XCTAssertEqual(PageDiagnostics.outcome(result: nil, error: nil), .notProvided(note))
        XCTAssertEqual(PageDiagnostics.outcome(result: NSNull(), error: nil), .notProvided(note))
        let error = NSError(domain: "WKErrorDomain", code: 4, userInfo: [NSLocalizedDescriptionKey: "A JavaScript exception occurred"])
        XCTAssertEqual(PageDiagnostics.outcome(result: nil, error: error),
                       .notProvided(note + " The page answered with an error: A JavaScript exception occurred"))
        XCTAssertEqual(PageDiagnostics.outcome(result: "yes", error: nil),
                       .notProvided(note + " The page's answer wasn't an object."))
        XCTAssertEqual(PageDiagnostics.outcome(result: ["state": [String: Any]()] as [String: Any], error: nil),
                       .notProvided(note + " The page's answer had no version."))
        XCTAssertEqual(PageDiagnostics.timedOut(), .notProvided(note + " It didn't answer within 3 seconds."))
        XCTAssertEqual(PageDiagnostics.noPage(), .notProvided(note + " No app window had a page loaded."))
        XCTAssertEqual(PageDiagnostics.script,
                       "return await (window.__pnvDiagnostics ? window.__pnvDiagnostics() : null)")
    }

    // MARK: In the report

    func testTheReportStillWorksWhenThePageDidntAnswer() throws {
        var r = ReportSamples.request()
        r.page = PageDiagnostics.timedOut()
        XCTAssertEqual(ProblemReport.offered(r), [.versions, .startup, .logs, .system])
        let files = ReportSamples.build(r)
        XCTAssertNil(files.pageState)
        XCTAssertNil(files.pageActivity)
        XCTAssertTrue(files.markdown.contains(
            "- No PsyNeuView diagnostics: PsyNeuView didn't provide its diagnostics (older version or not loaded). "
            + "It didn't answer within 3 seconds."))
        XCTAssertFalse(files.markdown.contains("page-state.json"))
        XCTAssertFalse(files.markdown.contains("Left out by the sender"), "nothing was offered, so nothing was left out")
        let json = ReportSamples.diagnostics(files)
        XCTAssertEqual(json["attachments"] as? [String], ["report.md", "screenshot-1.png", "logs.txt", "diagnostics.json"])
        let page = try XCTUnwrap(json["page"] as? [String: Any])
        XCTAssertEqual(page["provided"] as? Bool, false)
        XCTAssertTrue((page["note"] as? String ?? "").hasPrefix("PsyNeuView didn't provide its diagnostics"))
        // The View buttons say so too.
        XCTAssertTrue(ProblemReport.preview(.pageState, of: r, home: Self.home).hasPrefix("PsyNeuView didn't provide"))
    }

    func testWhatThePageProvidedIsAttachedAndListed() throws {
        var r = ReportSamples.request()
        r.page = PageDiagnostics.outcome(result: Self.answer, error: nil)
        XCTAssertEqual(ProblemReport.offered(r), [.versions, .startup, .logs, .pageState, .pageActivity, .system])
        let files = ReportSamples.build(r)
        let state = try XCTUnwrap(files.pageState)
        XCTAssertTrue(state.contains("\"path\" : \"~/models/stroop.py\""), "redacted again: \(state)")
        XCTAssertTrue(state.hasSuffix("}\n"))
        XCTAssertEqual(files.pageActivity?.components(separatedBy: "\n").count, 6, "5 lines and a final newline")
        XCTAssertTrue(files.pageActivity!.contains("Couldn't save ~/x token=[REDACTED]"))
        XCTAssertTrue(files.markdown.contains(
            "- page-state.json: PsyNeuView's state, as the page reported it (diagnostics version 1)"))
        XCTAssertTrue(files.markdown.contains(
            "- activity.txt: PsyNeuView's activity since launch, one line per entry: time · kind · text"))
        XCTAssertFalse(files.markdown.contains("No PsyNeuView diagnostics"))
        let json = ReportSamples.diagnostics(files)
        XCTAssertEqual(json["attachments"] as? [String],
                       ["report.md", "screenshot-1.png", "logs.txt", "page-state.json", "activity.txt", "diagnostics.json"])
        XCTAssertEqual((json["page"] as? [String: Any])?["version"] as? Int, 1)
        XCTAssertEqual(ProblemReport.preview(.pageActivity, of: r, home: Self.home)
            .components(separatedBy: "\n").count, 5)
        XCTAssertTrue(ProblemReport.preview(.pageState, of: r, home: Self.home).contains("~/models/stroop.py"))
    }

    /// Each page part can be unticked on its own, like the other parts.
    func testEachPagePartCanBeLeftOut() throws {
        var r = ReportSamples.request()
        r.page = PageDiagnostics.outcome(result: Self.answer, error: nil)
        r.included.remove(.pageState)
        let files = ReportSamples.build(r)
        XCTAssertNil(files.pageState)
        XCTAssertNotNil(files.pageActivity)
        XCTAssertTrue(files.markdown.contains("Left out by the sender: PsyNeuView's state, as the page reported it."))
        XCTAssertEqual(ReportSamples.diagnostics(files)["attachments"] as? [String],
                       ["report.md", "screenshot-1.png", "logs.txt", "activity.txt", "diagnostics.json"])
        XCTAssertEqual(ReportSamples.diagnostics(files)["omitted"] as? [String], ["pageState"])
    }

    /// The included list, in order, with everything #208 added, and the
    /// file each part becomes.
    func testTheIncludedItemsListInFull() throws {
        var r = ReportSamples.request()
        r.settings = SettingsSnapshotTests.values
        r.previousLogLines = ["earlier"]
        r.page = PageDiagnostics.outcome(result: Self.fullAnswer, error: nil)
        XCTAssertEqual(ProblemReport.offered(r), ProblemReport.Part.allCases)
        XCTAssertEqual(ProblemReport.Part.allCases.map(\.title), [
            "Versions, and where PsyNeuView runs from",
            "Startup and update outcome",
            "Every app setting (no tokens or addresses)",
            "This launch's whole log",
            "The previous launch's log (this launch is under 2 minutes old)",
            "PsyNeuView's state, as the page reported it",
            "PsyNeuView's activity since launch",
            "PsyNeuView's activity in the previous launch",
            "One timeline: what you did, errors, waits and the server log, in time order",
            "macOS version and Mac model",
        ])
        XCTAssertEqual(ProblemReport.Part.allCases.map(\.fileName),
                       [nil, nil, nil, "logs.txt", "logs-previous-launch.txt", "page-state.json", "activity.txt",
                        "activity-previous-launch.txt", "timeline.txt", nil])
        let files = ReportSamples.build(r)
        XCTAssertEqual(files.attachments(screenshots: ["screenshot-1.png"]), [
            "report.md", "screenshot-1.png", "logs.txt", "logs-previous-launch.txt",
            "page-state.json", "activity.txt", "activity-previous-launch.txt", "timeline.txt", "diagnostics.json",
        ])
        XCTAssertEqual(ReportSamples.diagnostics(files)["attachments"] as? [String],
                       files.attachments(screenshots: ["screenshot-1.png"]))
        let folder = try XCTUnwrap(files.markdown.range(of: "## In this folder"))
        let listing = files.markdown[folder.upperBound...]
        for name in files.attachments(screenshots: ["screenshot-1.png"]) {
            XCTAssertTrue(listing.contains("- \(name):"), "\(name) isn't listed")
        }
    }
}
