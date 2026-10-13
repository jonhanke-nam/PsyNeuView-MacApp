import Foundation
import XCTest
@testable import PsyNeuView

/// Report a Problem's contents (#202): what's in the report, what's redacted,
/// the size caps, and the prefilled links.
final class ProblemReportTests: XCTestCase {

    static let home = "/Users/someone"
    static let utc = TimeZone(identifier: "UTC")!
    // 2026-10-06 14:03:22 UTC
    static let date = Date(timeIntervalSince1970: 1_791_295_402)

    static let facts = ProblemReport.Facts(
        appVersion: "0.5.15", appBuild: "42",
        psyNeuViewVersion: "0.5.9",
        install: "PsyNeuView 0.5.9, included with this app",
        psyNeuLinkSource: "github:devel",
        psyNeuLinkVersion: "0.19.1.0",
        developerMode: false,
        server: "running",
        startupOutcome: "started in 38.2 s",
        moveOutcome: "2026-10-05 09:12: moved to PsyNeuView 0.5.9",
        steps: [
            .init(title: "Install PsyNeuView", status: "done in 3.1 s"),
            .init(title: "Start the server and load PsyNeuLink", status: "done in 35.0 s"),
        ],
        macOSVersion: "Version 26.0 (Build 25A354)",
        macModel: "Mac15,6")

    func request(
        what: String = "The Open menu shows four sections.",
        expected: String = "One section.",
        logs: [String] = ["[10:00:00.000] [System] Starting"],
        included: Set<ProblemReport.Part> = Set(ProblemReport.Part.allCases),
        screenshots: [String] = ["screenshot-1.png"]
    ) -> ProblemReport.Request {
        ProblemReport.Request(
            whatHappened: what, expected: expected, facts: Self.facts, logLines: logs,
            included: included, screenshots: screenshots, screenshotNote: nil,
            reference: ProblemReport.reference(for: Self.date, timeZone: Self.utc),
            date: Self.date)
    }

    func build(_ r: ProblemReport.Request) -> ProblemReport.Files {
        ProblemReport.build(r, home: Self.home, timeZone: Self.utc)
    }

    func diagnostics(_ files: ProblemReport.Files) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: files.diagnostics) as? [String: Any])
    }

    /// The reported case behind #205: a PsyNeuView too old for the app's Settings.
    func testTheReportSaysWhenPsyNeuViewIsTooOldForTheAppsSettings() throws {
        var r = request()
        r.facts.settingsSupport = SettingsSupport.reportLine(.tooOld(version: "0.5.6"))
        let files = build(r)
        XCTAssertTrue(files.markdown.contains(
            "App's Settings: too old: 0.5.6 is older than 0.5.9, which the app's Settings need"))
        let versions = try XCTUnwrap(try diagnostics(files)["versions"] as? [String: Any])
        XCTAssertEqual(versions["settingsSupport"] as? String,
                       "too old: 0.5.6 is older than 0.5.9, which the app's Settings need")
        XCTAssertTrue(ProblemReport.summary(r, home: Self.home).contains("PsyNeuView is too old"))
    }

    // MARK: Naming

    func testTheFolderNameHasNoColons() {
        let name = ProblemReport.reference(for: Self.date, timeZone: Self.utc)
        XCTAssertEqual(name, "PNV-debugging-2026-10-06_14-03-22")
        XCTAssertFalse(name.contains(":"))
    }

    // MARK: Contents

    func testTheReportHasEveryFactWithTheDescriptionFirst() throws {
        let files = build(request())
        let md = files.markdown
        for expected in [
            "Reference: **PNV-debugging-2026-10-06_14-03-22**",
            "## What happened", "The Open menu shows four sections.",
            "## What I expected", "One section.",
            "PsyNeuView app: 0.5.15 (build 42)",
            "PsyNeuView: 0.5.9",
            "Runs from: PsyNeuView 0.5.9, included with this app",
            "PsyNeuLink: 0.19.1.0, from github:devel",
            "This launch: started in 38.2 s",
            "Move to the included PsyNeuView (#186): 2026-10-05 09:12: moved to PsyNeuView 0.5.9",
            "  - Install PsyNeuView: done in 3.1 s",
            "macOS: Version 26.0 (Build 25A354)",
            "Model: Mac15,6",
            "- screenshot-1.png: a screenshot",
            "- logs.txt: this launch's whole log (1 line)",
        ] {
            XCTAssertTrue(md.contains(expected), "report.md is missing \(expected)")
        }
        let what = try XCTUnwrap(md.range(of: "## What happened"))
        let versions = try XCTUnwrap(md.range(of: "## Versions"))
        XCTAssertLessThanOrEqual(what.lowerBound, versions.lowerBound)

        let json = try diagnostics(files)
        XCTAssertEqual(json["reference"] as? String, "PNV-debugging-2026-10-06_14-03-22")
        let v = try XCTUnwrap(json["versions"] as? [String: Any])
        XCTAssertEqual(v["runsFrom"] as? String, "PsyNeuView 0.5.9, included with this app")
        XCTAssertEqual(v["psyNeuLink"] as? String, "0.19.1.0")
        let s = try XCTUnwrap(json["startup"] as? [String: Any])
        XCTAssertEqual((s["steps"] as? [[String: String]])?.count, 2)
        XCTAssertEqual(json["attachments"] as? [String],
                       ["report.md", "screenshot-1.png", "logs.txt", "diagnostics.json"])
        XCTAssertEqual(files.logs, "[10:00:00.000] [System] Starting\n")
    }

    func testAnUncheckedPartIsLeftOutAndSaidSo() throws {
        let files = build(request(included: [.versions]))
        XCTAssertNil(files.logs)
        XCTAssertFalse(files.markdown.contains("## Startup and update"))
        XCTAssertFalse(files.markdown.contains("Mac15,6"))
        XCTAssertFalse(files.markdown.contains("logs.txt"))
        XCTAssertTrue(files.markdown.contains("Left out by the sender: Startup and update outcome"))
        let json = try diagnostics(files)
        XCTAssertNil(json["startup"])
        XCTAssertNil(json["system"])
        XCTAssertEqual(json["omitted"] as? [String], ["startup", "logs", "system"],
                       "only offered parts are listed: no settings were gathered, no previous launch, no page")
    }

    func testNoScreenshotSaysWhy() {
        var r = request(screenshots: [])
        r.screenshotNote = "No app window was open."
        XCTAssertTrue(build(r).markdown.contains("- No screenshot: No app window was open."))
    }

    func testAnEmptyDescriptionIsMarked() {
        XCTAssertTrue(build(request(what: "  \n")).markdown.contains("_(not described)_"))
    }

    func testEachPartsPreviewIsWhatGetsSent() {
        var r = request(logs: ["at /Users/someone/x token=abc123"])
        r.facts.install = "your checkout at /Users/someone/code (devel)"
        XCTAssertTrue(ProblemReport.preview(.versions, of: r, home: Self.home)
            .contains("Runs from: your checkout at ~/code (devel)"))
        XCTAssertTrue(ProblemReport.preview(.startup, of: r, home: Self.home)
            .contains("Install PsyNeuView: done in 3.1 s"))
        XCTAssertEqual(ProblemReport.preview(.logs, of: r, home: Self.home), "at ~/x token=[REDACTED]")
        XCTAssertEqual(ProblemReport.preview(.system, of: r, home: Self.home),
                       "macOS: Version 26.0 (Build 25A354)\nModel: Mac15,6")
    }

    // MARK: Redaction

    func testSecretsAreRemoved() {
        let samples: [(String, String)] = [
            ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 used", "ghp_abcdefghij"),
            ("oauth gho_ABCDEFGHIJKLMNOPQRST1234 ok", "gho_ABCDEFGHIJ"),
            ("pat github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "github_pat_11ABCDEFG"),
            ("git clone https://x-access-token:s3cr3tvalue@github.com/a/b.git", "s3cr3tvalue"),
            ("fetch https://jon:hunter2@example.com/x", "hunter2"),
            ("Authorization: Bearer abc.def.ghi", "abc.def.ghi"),
            ("authorization=token zzzzzzzz", "zzzzzzzz"),
            ("GET /cb?code=1&token=AbC123xyz&state=2", "AbC123xyz"),
            ("PASSWORD=pa55word ./run", "pa55word"),
            ("client_secret: \"quoted secret\"", "quoted secret"),
        ]
        for (input, secret) in samples {
            let out = ProblemReport.redact(input, home: Self.home)
            XCTAssertFalse(out.contains(secret), "\(input) → \(out)")
            XCTAssertTrue(out.contains("[REDACTED]"), "\(input) → \(out)")
        }
        // What's around a secret survives, so the line still reads.
        XCTAssertEqual(
            ProblemReport.redact("git clone https://x-access-token:abc@github.com/a/b.git", home: Self.home),
            "git clone https://x-access-token:[REDACTED]@github.com/a/b.git")
        XCTAssertEqual(
            ProblemReport.redact("GET /cb?code=1&token=AbC123xyz&state=2", home: Self.home),
            "GET /cb?code=1&token=[REDACTED]&state=2")
    }

    func testTheHomeFolderIsShownAsTilde() {
        XCTAssertEqual(
            ProblemReport.redact("Now running from /Users/someone/Library/x and /Users/someone.", home: Self.home),
            "Now running from ~/Library/x and ~.")
        // Another account's folder isn't the home folder.
        XCTAssertEqual(
            ProblemReport.redact("/Users/someoneelse/x", home: Self.home), "/Users/someoneelse/x")
    }

    func testTheHomeFolderIsHiddenInEncodedForms() {
        // Request URLs in the backend log carry it percent-encoded (#2).
        XCTAssertEqual(
            ProblemReport.redact("GET /api/model/edit-mode?file_path=%2FUsers%2Fsomeone%2FLibrary%2Fx", home: Self.home),
            "GET /api/model/edit-mode?file_path=~%2FLibrary%2Fx")
        XCTAssertEqual(ProblemReport.redact("p=%2fUsers%2fsomeone%2fx", home: Self.home), "p=~%2fx")
        // JSON-escaped.
        XCTAssertEqual(ProblemReport.redact(#"{"path":"\/Users\/someone\/x"}"#, home: Self.home), #"{"path":"~\/x"}"#)
        // A space in the home folder, encoded as %20 or +.
        XCTAssertEqual(ProblemReport.redact("%2FUsers%2Fsome%20one%2Fx", home: "/Users/some one"), "~%2Fx")
        XCTAssertEqual(ProblemReport.redact("%2FUsers%2Fsome+one%2Fx", home: "/Users/some one"), "~%2Fx")
        // Another account stays, encoded or not.
        XCTAssertEqual(ProblemReport.redact("%2FUsers%2Fsomeoneelse%2Fx", home: Self.home), "%2FUsers%2Fsomeoneelse%2Fx")
    }

    func testTheAccountsUsersFolderIsHiddenWhenHomeIsElsewhere() {
        XCTAssertEqual(
            ProblemReport.shortenHome("/Users/someone/x and %2FUsers%2Fsomeone%2Fy", home: "/private/var/home", userName: "someone"),
            "~/x and ~%2Fy")
    }

    func testEverythingThatLeavesIsRedacted() throws {
        var r = request(
            what: "Saw ghp_abcdefghijklmnopqrstuvwxyz0123 in /Users/someone/code",
            logs: ["cloning https://x-access-token:topsecret@github.com/x at /Users/someone/y"])
        r.facts.install = "your checkout at /Users/someone/code/PsyNeuView (devel)"
        let files = build(r)
        let json = String(decoding: files.diagnostics, as: UTF8.self)
        for text in [files.markdown, files.logs ?? "", json, ProblemReport.summary(r, home: Self.home)] {
            XCTAssertFalse(text.contains("ghp_abc"))
            XCTAssertFalse(text.contains("topsecret"))
            XCTAssertFalse(text.contains("/Users/someone/"))
        }
        XCTAssertTrue(files.markdown.contains("your checkout at ~/code/PsyNeuView (devel)"))
    }

    // MARK: Size caps

    /// The whole launch goes in (#208): the file is size-capped by
    /// LaunchLog, so only a single runaway line is cut here.
    func testLogsKeepEveryLineEachCapped() throws {
        let lines = (1...800).map { "line \($0)" } + [String(repeating: "x", count: 5_000)]
        let logs = try XCTUnwrap(build(request(logs: lines)).logs)
        let kept = logs.split(separator: "\n")
        XCTAssertEqual(kept.count, 801)
        XCTAssertEqual(kept.first, "line 1")
        XCTAssertTrue(kept.last!.hasSuffix("[line cut at 2000 characters]"))
        XCTAssertLessThanOrEqual(kept.last!.count, ProblemReport.maxLogLineLength + 40)
    }

    /// The View button shows the newest lines and says the file has the
    /// rest; the popover is for a look.
    func testTheLogPreviewIsShortAndSaysSo() {
        let lines = (1...800).map { "line \($0) at /Users/someone/x" }
        let preview = ProblemReport.preview(.logs, of: request(logs: lines), home: Self.home)
        let shown = preview.split(separator: "\n")
        XCTAssertEqual(shown.first, "(the newest 200 of 800 lines; the report has all of them)")
        XCTAssertEqual(shown.count, ProblemReport.logPreviewLines + 1)
        XCTAssertEqual(shown[1], "line 601 at ~/x")
        XCTAssertEqual(shown.last, "line 800 at ~/x")
        XCTAssertEqual(ProblemReport.preview(.logs, of: request(logs: ["a"]), home: Self.home), "a",
                       "no note when the file has no more than the preview")
        XCTAssertEqual(ProblemReport.preview(.logs, of: request(logs: []), home: Self.home), "(no log lines yet)")
    }

    // MARK: The previous launch (#208)

    func testThePreviousLaunchIsAttachedOnlyWhenThisLaunchIsYoung() {
        XCTAssertTrue(ProblemReport.attachPreviousLaunch(launchAge: 30, previousAvailable: true))
        XCTAssertFalse(ProblemReport.attachPreviousLaunch(launchAge: 30, previousAvailable: false))
        XCTAssertFalse(ProblemReport.attachPreviousLaunch(launchAge: ProblemReport.shortLaunch, previousAvailable: true))
        XCTAssertFalse(ProblemReport.attachPreviousLaunch(launchAge: 3_600, previousAvailable: true))
    }

    func testThePreviousLaunchsLogIsAFileAndIsSaidToBeIncluded() throws {
        var r = request()
        r.previousLogLines = ["[2026-10-06 13:59:00.000] [System] launched", "[2026-10-06 13:59:40.000] [Backend] [error] died at /Users/someone/p"]
        XCTAssertTrue(ProblemReport.offered(r).contains(.previousLogs))
        let files = build(r)
        XCTAssertEqual(files.previousLogs,
                       "[2026-10-06 13:59:00.000] [System] launched\n[2026-10-06 13:59:40.000] [Backend] [error] died at ~/p\n")
        XCTAssertTrue(files.markdown.contains(
            "- logs-previous-launch.txt: the previous launch's log (2 lines), included because this launch was under 2 minutes old"))
        let json = try diagnostics(files)
        XCTAssertEqual(json["attachments"] as? [String],
                       ["report.md", "screenshot-1.png", "logs.txt", "logs-previous-launch.txt", "diagnostics.json"])
        XCTAssertEqual((json["previousLaunchLog"] as? [String: Any])?["lines"] as? Int, 2)

        // Unticked: not written, and said to be left out.
        r.included.remove(.previousLogs)
        let without = build(r)
        XCTAssertNil(without.previousLogs)
        XCTAssertFalse(without.markdown.contains("logs-previous-launch.txt"))
        XCTAssertTrue(without.markdown.contains("Left out by the sender: The previous launch's log"))

        // Not offered at all when there is none: nothing said either way.
        XCTAssertFalse(ProblemReport.offered(request()).contains(.previousLogs))
        XCTAssertFalse(build(request()).markdown.contains("previous launch"))
    }

    func testALongDescriptionIsCut() {
        let md = build(request(what: String(repeating: "a", count: 20_000))).markdown
        XCTAssertTrue(md.contains("[cut at 10000 characters]"))
        XCTAssertLessThanOrEqual(md.count, 12_000)
    }

    // MARK: Links

    func testTheIssueLinkIsPrefilledAndEncoded() throws {
        let url = try XCTUnwrap(ProblemReport.issueURL(
            request(what: "Open menu & Settings: wrong?\nmore"), repo: .macApp, home: Self.home))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://github.com/jonhanke-nam/PsyNeuView-MacApp/issues/new?title="))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "title" }?.value,
                       "Problem report: Open menu & Settings: wrong?")
        let body = try XCTUnwrap(items.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("PNV-debugging-2026-10-06_14-03-22"))
        XCTAssertTrue(body.contains("Drag the screenshot in here"))
        XCTAssertTrue(body.contains("[10:00:00.000] [System] Starting"))
        // `&`, `?` and `:` in the text don't break the query.
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(ProblemReport.issueURL(request(), repo: .psyNeuView, home: Self.home)!
            .absoluteString.hasPrefix("https://github.com/jonhanke-nam/PsyNeuView/issues/new?"))
    }

    /// The repositories are public, so a report must not become a public issue.
    func testGitHubIssuesAreOffWhileTheReposArePublic() {
        XCTAssertFalse(ProblemReport.githubIssuesEnabled)
    }

    func testALongIssueLinkIsCutWithANote() throws {
        let logs = (1...400).map { "log line number \($0) with some ünïcode text" }
        let url = try XCTUnwrap(ProblemReport.issueURL(
            request(logs: logs), repo: .macApp, home: Self.home, maxLength: 3_000))
        XCTAssertLessThanOrEqual(url.absoluteString.count, 3_000)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try XCTUnwrap(items.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.hasSuffix("_(Cut to fit a GitHub link. The full report is in PNV-debugging-2026-10-06_14-03-22.)_"))
        XCTAssertTrue(body.hasPrefix("PsyNeuView problem report"))
    }

    func testTheGmailLinkAsksForTheFolder() throws {
        let url = try XCTUnwrap(ProblemReport.gmailURL(request(), to: "help@example.org", home: Self.home))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (n: String) in items.first { $0.name == n }?.value }
        XCTAssertEqual(url.host, "mail.google.com")
        XCTAssertEqual(value("view"), "cm")
        XCTAssertEqual(value("to"), "help@example.org")
        XCTAssertEqual(value("su"), "PsyNeuView problem report PNV-debugging-2026-10-06_14-03-22")
        // A link can't attach files (#5): the request to attach is the first line.
        XCTAssertTrue(value("body")?.hasPrefix("Please attach PNV-debugging-2026-10-06_14-03-22.zip before sending") ?? false)
    }

    func testTheGmailAttachRequestSurvivesACut() throws {
        // A long report is cut to fit the link; the cut is at the end, so the
        // attach request, now first, is always kept (#5).
        let url = try XCTUnwrap(ProblemReport.gmailURL(request(), to: "help@example.org", home: Self.home, maxLength: 700))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try XCTUnwrap(items.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.hasPrefix(ProblemReport.gmailAttachRequest(request())))
        XCTAssertLessThanOrEqual(url.absoluteString.count, 700)
    }

    func testTheInstructionsNameTheContact() {
        XCTAssertTrue(ProblemReport.sendInstructions(reference: "R", sendTo: "help@example.org")
            .hasSuffix("attach it to an email to help@example.org."))
        // Cleared, "Send to" means the default contact.
        XCTAssertTrue(ProblemReport.sendInstructions(reference: "R", sendTo: " ")
            .hasSuffix("attach it to an email to \(ReportDefaults.contactEmail)."))
        XCTAssertEqual(ProblemReport.contact(""), ReportDefaults.contactEmail)
        XCTAssertEqual(ProblemReport.contact("a@b.co"), "a@b.co")
    }

    // MARK: Send with (#202)

    func testSendPlanFollowsTheSettingAndFallsBack() {
        typealias P = ProblemReport
        let mail = P.MailSetup(defaultMailApp: "com.apple.mail", outlookInstalled: false)
        let outlook = P.MailSetup(defaultMailApp: "com.microsoft.Outlook", outlookInstalled: true)
        let none = P.MailSetup(defaultMailApp: nil, outlookInstalled: false)
        let outlookNotDefault = P.MailSetup(defaultMailApp: "com.apple.mail", outlookInstalled: true)

        XCTAssertEqual(P.sendPlan(.ask, setup: mail), P.SendPlan(preferred: nil, emailAvailable: true, notice: nil))
        XCTAssertNotNil(P.sendPlan(.ask, setup: none).notice)
        XCTAssertFalse(P.sendPlan(.ask, setup: none).emailAvailable)

        XCTAssertEqual(P.sendPlan(.mail, setup: mail).preferred, .email)
        XCTAssertNil(P.sendPlan(.mail, setup: none).preferred)
        XCTAssertTrue(P.sendPlan(.mail, setup: none).notice?.contains("no mail app") ?? false)

        XCTAssertEqual(P.sendPlan(.outlook, setup: outlook).preferred, .email)
        XCTAssertNil(P.sendPlan(.outlook, setup: outlookNotDefault).preferred)
        XCTAssertTrue(P.sendPlan(.outlook, setup: outlookNotDefault).notice?.contains("isn't your default") ?? false)
        XCTAssertTrue(P.sendPlan(.outlook, setup: none).notice?.contains("isn't installed") ?? false)

        XCTAssertEqual(P.sendPlan(.gmail, setup: none).preferred, .gmail)
        XCTAssertEqual(P.SendWith(setting: "nonsense"), .ask)
    }
}
