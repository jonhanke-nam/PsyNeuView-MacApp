import Foundation

/// Who problem reports go to, unless Settings says otherwise (#202).
enum ReportDefaults {
    /// Interim until a shared pnv-support@ inbox exists; change here. The
    /// default for Settings ▸ Mac app ▸ "Send to", named in the how-to-send
    /// instructions, and the address Email and Gmail are pre-addressed to.
    static let contactEmail = "jonhanke@princeton.edu"
}

/// What Report a Problem saves (#202), as pure functions over plain inputs.
///
/// A 0.5.14 user saw the old Settings, and the only report that could be passed
/// on was a description and a screenshot of the wrong window. Working out the
/// cause needed facts nobody could easily collect: where PsyNeuView runs from,
/// whether the #186 move happened, and the log lines. This gathers them in one
/// click, with tokens and passwords removed and the home folder shown as `~`.
///
/// Nothing here touches the disk, the window or the network, so every rule —
/// what's in the report, what's redacted, how big it may get, how the links
/// are encoded — is tested directly. `ReportWriter` saves the result.
enum ProblemReport {

    // MARK: Inputs

    /// The facts the app gathers when the report is made.
    struct Facts: Equatable {
        var appVersion: String
        var appBuild: String?
        /// The PsyNeuView version in use, when known.
        var psyNeuViewVersion: String?
        /// Where PsyNeuView runs from: `InstallSwitch.describeRunning` (#195).
        var install: String
        /// `Preferences.pnlSourceDescription`: "github:devel", "pypi", …
        var psyNeuLinkSource: String
        var psyNeuLinkVersion: String?
        var developerMode: Bool
        /// "running", "starting", "stopped"…
        var server: String
        /// How this launch's start went: "started in 38.2 s", or the failure
        /// the starting window showed.
        var startupOutcome: String?
        /// The last move to the included PsyNeuView (#186), with its date.
        var moveOutcome: String?
        /// Whether that PsyNeuView is new enough for the app's Settings
        /// (`SettingsSupport.reportLine`, #205).
        var settingsSupport: String?
        /// The last start's checklist (#196).
        var steps: [Step]
        var macOSVersion: String
        var macModel: String
        /// The page preferences the app keeps across launches (#218), by
        /// key name only — the values are the user's. Says whether the Open
        /// menu order or the pointer size could have survived a relaunch.
        var pagePreferenceKeys: [String] = []
    }

    struct Step: Equatable {
        var title: String
        /// "done in 12.3 s", "not needed", "failed: …", "running", "not reached"
        var status: String
    }

    /// The parts a user can leave out, each listed with a checkbox and a View
    /// button. The description is always in: it's the report. Some parts are
    /// only offered when there is something to offer (`offered(_:)`): the
    /// previous launch's log, and what the page provided (#208).
    enum Part: String, CaseIterable, Identifiable, Sendable {
        case versions
        case startup
        case settings
        case logs
        case previousLogs
        case pageState
        case pageActivity
        case system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .versions: return "Versions, and where PsyNeuView runs from"
            case .startup: return "Startup and update outcome"
            case .settings: return "Every app setting (no tokens or addresses)"
            case .logs: return "This launch's whole log"
            case .previousLogs:
                return "The previous launch's log (this launch is under \(Int(ProblemReport.shortLaunch / 60)) minutes old)"
            case .pageState: return "PsyNeuView's state, as the page reported it"
            case .pageActivity: return "PsyNeuView's activity since launch"
            case .system: return "macOS version and Mac model"
            }
        }

        /// The file in the report folder, for the parts that are one.
        var fileName: String? {
            switch self {
            case .logs: return "logs.txt"
            case .previousLogs: return "logs-previous-launch.txt"
            case .pageState: return "page-state.json"
            case .pageActivity: return "activity.txt"
            default: return nil
            }
        }
    }

    // MARK: Limits

    /// The in-window preview shows this many of the newest lines; the file
    /// has them all (#208).
    static let logPreviewLines = 200
    /// A launch younger than this gets the previous launch's log attached
    /// too (#208): the problem was likely a failed start.
    static let shortLaunch: TimeInterval = 120
    /// A single runaway line (a pip dump, a base64 blob) can't swamp the file.
    static let maxLogLineLength = 2_000
    /// The in-window preview of the page's state; the file has all of it.
    static let statePreviewBytes = 20 * 1024
    static let maxDescriptionLength = 10_000
    /// Whole links stay under what browsers and GitHub reliably accept.
    static let maxURLLength = 8_000

    // MARK: Naming

    static let folderPrefix = "PNV-debugging-"

    /// `PNV-debugging-YYYY-MM-DD_HH-MM-SS`, in local time. Hyphens, not
    /// colons: Finder doesn't allow `:` in names. The name is the report's
    /// reference, the way Feedback Assistant gives an FB number.
    static func reference(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return folderPrefix + f.string(from: date)
    }

    // MARK: Redaction

    /// Patterns for secrets, each with its replacement. Applied to everything
    /// that leaves the app — description, facts and logs alike.
    private static let secretPatterns: [(NSRegularExpression, String)] = {
        func re(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            // Credentials in a URL: https://x-access-token:SECRET@github.com,
            // https://user:password@host.
            (re(#"(x-access-token:)[^@\s/]+@"#), "$1[REDACTED]@"),
            (re(#"(\b[a-z][a-z0-9+.-]*://)(?!x-access-token:)[^/\s:@]+:[^/\s@]+@"#), "$1[REDACTED]@"),
            // Authorization headers, whatever the scheme.
            (re(#"(authorization["']?\s*[:=]\s*)[^\r\n]+"#), "$1[REDACTED]"),
            // GitHub tokens: classic and OAuth/app/refresh (ghp_, gho_, ghu_,
            // ghs_, ghr_), and fine-grained (github_pat_).
            (re(#"\bgithub_pat_[A-Za-z0-9_]{10,}"#), "[REDACTED]"),
            (re(#"\bgh[pousr]_[A-Za-z0-9]{10,}"#), "[REDACTED]"),
            // key=value and key: value secrets, in query strings, env dumps
            // and config lines.
            // Not after "-", so x-access-token (above) is left as it is.
            (re(#"(?<![-\w])((?:access_|refresh_|id_|auth_|api_|client_)?token|password|passwd|pwd|secret|client_secret|api_?key)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s&"',;]+)"#),
             "$1$2[REDACTED]"),
            // Bearer tokens outside a header line.
            (re(#"\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#), "$1[REDACTED]"),
        ]
    }()

    /// Remove secrets, and show the home folder as `~`.
    static func redact(_ text: String, home: String = NSHomeDirectory(), userName: String = NSUserName()) -> String {
        var s = text
        for (regex, template) in secretPatterns {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return shortenHome(s, home: home, userName: userName)
    }

    /// `/Users/someone/x` → `~/x`, only at a path boundary, so
    /// `/Users/someoneelse` is left alone.
    ///
    /// Also the forms the home folder takes in logs (#2): percent-encoded in
    /// request URLs (`%2FUsers%2Fsomeone`, either case, `%20` or `+` for a
    /// space), JSON-escaped (`\/Users\/someone`), and `/Users/<account>` when
    /// the home folder is somewhere else.
    static func shortenHome(_ text: String, home: String, userName: String = NSUserName()) -> String {
        var homes: [String] = []
        for candidate in [home, userName.isEmpty ? "" : "/Users/" + userName] {
            let trimmed = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
            if trimmed.count > 1, !homes.contains(trimmed) { homes.append(trimmed) }
        }
        let boundary = #"(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])"#
        var s = text
        for h in homes {
            let plain = NSRegularExpression.escapedPattern(for: h)
            let json = NSRegularExpression.escapedPattern(for: h.replacingOccurrences(of: "/", with: #"\/"#))
            // Percent-encoded: "/" may be %2F or %2f; a space %20 or "+".
            let encoded = h.map { ch -> String in
                switch ch {
                case "/": return "%2[Ff]"
                case " ": return "(?:%20|\\+)"
                default: return NSRegularExpression.escapedPattern(for: String(ch))
                }
            }.joined()
            for pattern in [plain, json, encoded] {
                guard let regex = try? NSRegularExpression(pattern: pattern + boundary) else { continue }
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "~")
            }
        }
        return s
    }

    // MARK: Logs

    /// Every line, each capped, redacted. The whole launch goes in (#208);
    /// the launch log file is already size-capped.
    static func redactedLog(_ lines: [String], home: String = NSHomeDirectory()) -> [String] {
        lines.map { line in
            let capped = line.count > maxLogLineLength
                ? String(line.prefix(maxLogLineLength)) + " … [line cut at \(maxLogLineLength) characters]"
                : line
            return redact(capped, home: home)
        }
    }

    /// The newest `logPreviewLines` lines, with a line saying so when the
    /// file has more: the View button's text (#208).
    static func logPreview(_ lines: [String], home: String = NSHomeDirectory()) -> String {
        guard !lines.isEmpty else { return "(no log lines yet)" }
        let shown = redactedLog(Array(lines.suffix(logPreviewLines)), home: home)
        var out: [String] = []
        if lines.count > shown.count {
            out.append("(the newest \(shown.count) of \(lines.count) lines; the report has all of them)")
        }
        return (out + shown).joined(separator: "\n")
    }

    /// Whether to attach the previous launch's log too: when this launch is
    /// young, the problem was probably a start that failed, and that launch
    /// is where the evidence is (#208).
    static func attachPreviousLaunch(launchAge: TimeInterval, previousAvailable: Bool) -> Bool {
        previousAvailable && launchAge < shortLaunch
    }

    // MARK: The report

    struct Files: Equatable {
        /// `report.md`: readable, the user's words first.
        var markdown: String
        /// `diagnostics.json`: the same facts, for tools.
        var diagnostics: Data
        /// `logs.txt`, or nil when left out.
        var logs: String?
        /// `logs-previous-launch.txt`, when attached (#208).
        var previousLogs: String?
        /// `page-state.json`, when the page provided it (#208).
        var pageState: String?
        /// `activity.txt`, when the page provided it (#208).
        var pageActivity: String?

        /// The files in the folder, in the order written: what `ReportWriter`
        /// saves and what the report lists.
        func attachments(screenshots: [String]) -> [String] {
            var names = ["report.md"] + screenshots
            if logs != nil { names.append(Part.logs.fileName!) }
            if previousLogs != nil { names.append(Part.previousLogs.fileName!) }
            if pageState != nil { names.append(Part.pageState.fileName!) }
            if pageActivity != nil { names.append(Part.pageActivity.fileName!) }
            names.append("diagnostics.json")
            return names
        }
    }

    struct Request: Equatable {
        var whatHappened: String
        var expected: String
        var facts: Facts
        /// This launch's log, every line (#208).
        var logLines: [String]
        /// The previous launch's log, when it's to be offered (#208).
        var previousLogLines: [String]? = nil
        /// Every app setting (#208); nil when not gathered.
        var settings: SettingsSnapshot.Values? = nil
        /// What the page provided (#208).
        var page: PageDiagnostics.Outcome = .notProvided(PageDiagnostics.notProvidedNote)
        var included: Set<Part> = Set(Part.allCases)
        /// Screenshot file names, in order, as they'll be saved.
        var screenshots: [String] = []
        /// Why there is no screenshot, when there isn't one.
        var screenshotNote: String?
        var reference: String
        var date: Date
    }

    /// The parts this report can offer, in `Part` order: all of them, less
    /// the ones with nothing behind them.
    static func offered(_ r: Request) -> [Part] {
        Part.allCases.filter { part in
            switch part {
            case .previousLogs: return r.previousLogLines != nil
            case .settings: return r.settings != nil
            case .pageState, .pageActivity: return r.page.provided != nil
            default: return true
            }
        }
    }

    /// Offered and ticked.
    static func includes(_ r: Request, _ part: Part) -> Bool {
        r.included.contains(part) && offered(r).contains(part)
    }

    static func build(_ r: Request, home: String = NSHomeDirectory(),
                      timeZone: TimeZone = .current) -> Files {
        let clean = { (s: String) in redact(s, home: home) }
        let whatHappened = clean(capped(r.whatHappened))
        let expected = clean(capped(r.expected))
        let f = redacted(r.facts, home: home)
        let logs = includes(r, .logs) ? redactedLog(r.logLines, home: home) : nil
        let previousLogs = includes(r, .previousLogs) ? r.previousLogLines.map { redactedLog($0, home: home) } : nil
        let page = r.page.provided
        let pageState = includes(r, .pageState) ? page.map { clean($0.stateJSON) + "\n" } : nil
        let pageActivity = includes(r, .pageActivity)
            ? page.map { PageDiagnostics.activityText($0.activityLines, home: home) } : nil
        let settings = includes(r, .settings) ? r.settings : nil
        let saved = timestamp(r.date, timeZone: timeZone)

        var md: [String] = []
        md.append("# PsyNeuView problem report")
        md.append("")
        md.append("Reference: **\(r.reference)**  ")
        md.append("Saved: \(saved)")
        md.append("")
        md.append("## What happened")
        md.append("")
        md.append(whatHappened.isEmpty ? "_(not described)_" : whatHappened)
        if !expected.isEmpty {
            md.append("")
            md.append("## What I expected")
            md.append("")
            md.append(expected)
        }
        if r.included.contains(.versions) {
            md.append("")
            md.append("## Versions")
            md.append("")
            md.append(contentsOf: versionLines(f).map { "- " + $0 })
        }
        if r.included.contains(.startup) {
            md.append("")
            md.append("## Startup and update")
            md.append("")
            md.append(contentsOf: startupLines(f).map { "- " + $0 })
            if !f.steps.isEmpty {
                md.append("- Last start, step by step:")
                md.append(contentsOf: f.steps.map { "  - \($0.title): \($0.status)" })
            }
        }
        if let settings {
            md.append("")
            md.append("## Settings")
            md.append("")
            md.append(contentsOf: SettingsSnapshot.lines(settings, home: home, timeZone: timeZone).map { "- " + $0 })
        }
        if r.included.contains(.system) {
            md.append("")
            md.append("## This Mac")
            md.append("")
            md.append("- macOS: \(f.macOSVersion)")
            md.append("- Model: \(f.macModel)")
        }
        let files = Files(
            markdown: "", diagnostics: Data(),
            logs: logs.map { $0.joined(separator: "\n") + "\n" },
            previousLogs: previousLogs.map { $0.joined(separator: "\n") + "\n" },
            pageState: pageState,
            pageActivity: pageActivity)
        md.append("")
        md.append("## In this folder")
        md.append("")
        md.append("- report.md: this summary")
        for name in r.screenshots { md.append("- \(name): a screenshot") }
        if r.screenshots.isEmpty, let note = r.screenshotNote {
            md.append("- No screenshot: \(clean(note))")
        }
        if let logs {
            md.append("- logs.txt: this launch's whole log (\(counted(logs.count, "line")))")
        }
        if let previousLogs {
            md.append("- logs-previous-launch.txt: the previous launch's log (\(counted(previousLogs.count, "line"))), "
                      + "included because this launch was under \(Int(shortLaunch / 60)) minutes old when the report was made")
        }
        if pageState != nil {
            md.append("- page-state.json: PsyNeuView's state, as the page reported it (diagnostics version \(page?.version ?? 0))")
        }
        if pageActivity != nil {
            md.append("- activity.txt: PsyNeuView's activity since launch, one line per entry: time · kind · text")
        }
        if page == nil {
            md.append("- No PsyNeuView diagnostics: \(clean(r.page.note))")
        }
        md.append("- diagnostics.json: the facts above, for tools")
        let omitted = offered(r).filter { !r.included.contains($0) }
        if !omitted.isEmpty {
            md.append("")
            md.append("Left out by the sender: " + omitted.map(\.title).joined(separator: "; ") + ".")
        }
        md.append("")
        md.append("_Tokens and passwords were removed, and the home folder is shown as `~`. "
                  + "Screenshots are saved as taken._")
        md.append("")

        // diagnostics.json
        var json: [String: Any] = [
            "reference": r.reference,
            "saved": saved,
            "whatHappened": whatHappened,
            "expected": expected,
            "attachments": files.attachments(screenshots: r.screenshots),
            "omitted": omitted.map(\.rawValue),
            "redaction": "tokens and passwords removed; home folder shown as ~",
            "page": [
                "provided": page != nil,
                "version": page?.version ?? NSNull(),
                "note": page == nil ? clean(r.page.note) : NSNull(),
            ] as [String: Any],
        ]
        if let settings {
            json["settings"] = SettingsSnapshot.dictionary(settings, home: home, timeZone: timeZone)
        }
        if let previousLogs {
            json["previousLaunchLog"] = ["lines": previousLogs.count,
                                         "why": "this launch was under \(Int(shortLaunch)) seconds old"] as [String: Any]
        }
        if r.included.contains(.versions) {
            json["versions"] = [
                "app": f.appVersion,
                "appBuild": f.appBuild ?? NSNull(),
                "psyNeuView": f.psyNeuViewVersion ?? NSNull(),
                "runsFrom": f.install,
                "settingsSupport": f.settingsSupport ?? NSNull(),
                "psyNeuLink": f.psyNeuLinkVersion ?? NSNull(),
                "psyNeuLinkSource": f.psyNeuLinkSource,
                "developerMode": f.developerMode,
                "pagePreferences": ["count": f.pagePreferenceKeys.count, "keys": f.pagePreferenceKeys] as [String: Any],
            ] as [String: Any]
        }
        if r.included.contains(.startup) {
            json["startup"] = [
                "server": f.server,
                "thisLaunch": f.startupOutcome ?? NSNull(),
                "moveToIncludedPsyNeuView": f.moveOutcome ?? NSNull(),
                "steps": f.steps.map { ["step": $0.title, "status": $0.status] },
            ] as [String: Any]
        }
        if r.included.contains(.system) {
            json["system"] = ["macOS": f.macOSVersion, "model": f.macModel]
        }
        if r.screenshots.isEmpty, let note = r.screenshotNote { json["screenshotNote"] = clean(note) }
        let data = (try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)

        var result = files
        result.markdown = md.joined(separator: "\n")
        result.diagnostics = data
        return result
    }

    /// Exactly what one part adds, redacted, for its View button: what you
    /// see is what's sent. The logs and the activity show their newest
    /// lines, and the state its start, with a line saying the file has it
    /// all: the popover is for a look, not for reading 5 MB.
    static func preview(_ part: Part, of r: Request, home: String = NSHomeDirectory(),
                        timeZone: TimeZone = .current) -> String {
        let f = redacted(r.facts, home: home)
        switch part {
        case .versions:
            return versionLines(f).joined(separator: "\n")
        case .startup:
            var lines = startupLines(f)
            if !f.steps.isEmpty {
                lines.append("Last start, step by step:")
                lines.append(contentsOf: f.steps.map { "  \($0.title): \($0.status)" })
            }
            return lines.joined(separator: "\n")
        case .settings:
            guard let settings = r.settings else { return "(settings weren't gathered)" }
            return SettingsSnapshot.lines(settings, home: home, timeZone: timeZone).joined(separator: "\n")
        case .logs:
            return logPreview(r.logLines, home: home)
        case .previousLogs:
            guard let previous = r.previousLogLines else { return "(no previous launch's log)" }
            return logPreview(previous, home: home)
        case .pageState:
            guard let page = r.page.provided else { return r.page.note }
            let json = redact(page.stateJSON, home: home)
            guard json.utf8.count > statePreviewBytes else { return json }
            return "(the first \(statePreviewBytes / 1024) KB; page-state.json has all of it)\n"
                + String(json.prefix(statePreviewBytes))
        case .pageActivity:
            guard let page = r.page.provided else { return r.page.note }
            return logPreview(page.activityLines, home: home)
        case .system:
            return "macOS: \(f.macOSVersion)\nModel: \(f.macModel)"
        }
    }

    /// A short text version for a chat message: reference, the user's words,
    /// versions, install and outcome.
    static func summary(_ r: Request, home: String = NSHomeDirectory()) -> String {
        let f = redacted(r.facts, home: home)
        var lines = ["PsyNeuView problem report \(r.reference)"]
        let what = redact(capped(r.whatHappened), home: home)
        lines.append("What happened: " + (what.isEmpty ? "(not described)" : what))
        let expected = redact(capped(r.expected), home: home)
        if !expected.isEmpty { lines.append("Expected: " + expected) }
        if r.included.contains(.versions) {
            var v = "App \(f.appVersion)"
            v += " · PsyNeuView \(f.psyNeuViewVersion ?? "?") (\(f.install))"
            v += " · PsyNeuLink \(f.psyNeuLinkVersion ?? "?") (\(f.psyNeuLinkSource))"
            lines.append(v)
            if let support = f.settingsSupport, support.hasPrefix("too old") {
                lines.append("PsyNeuView is " + support)
            }
        }
        if r.included.contains(.startup) {
            lines.append("Startup: " + (f.startupOutcome ?? f.server))
            if let move = f.moveOutcome { lines.append("Move to the included PsyNeuView: " + move) }
        }
        if r.included.contains(.system) {
            lines.append("Mac: macOS \(f.macOSVersion), \(f.macModel)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Links

    /// Characters left as they are in a query value; everything else is
    /// percent-encoded. ASCII only, spelled out, because
    /// `CharacterSet.alphanumerics` also passes non-ASCII letters through.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }

    /// `base?k=v&…`, with the last field cut until the whole link fits in
    /// `maxLength`, ending with `note` when it was cut.
    static func link(
        _ base: String, fields: [(String, String)], maxLength: Int = maxURLLength,
        truncationNote: String
    ) -> URL? {
        func assemble(_ fs: [(String, String)]) -> String {
            base + "?" + fs.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        }
        var fs = fields
        var full = assemble(fs)
        if full.count > maxLength, let last = fs.last {
            var body = last.1
            let note = "\n\n" + truncationNote
            while !body.isEmpty {
                // Encoded text runs up to 9 characters per character (a
                // 3-byte UTF-8 character), so cut in proportion to the excess.
                let excess = full.count - maxLength
                let cut = max(16, excess / 3)
                body = String(body.dropLast(min(cut, body.count)))
                fs[fs.count - 1] = (last.0, body + note)
                full = assemble(fs)
                if full.count <= maxLength { break }
            }
            if full.count > maxLength {
                fs[fs.count - 1] = (last.0, truncationNote)
                full = assemble(fs)
            }
        }
        return URL(string: full)
    }

    /// Whether developer mode offers "Open as GitHub issue". Off while both
    /// repositories are public (PsyNeuView since 2026-10-13, the Mac app next):
    /// a report carries logs and settings, and an issue there would publish
    /// them. Reports go by email or the saved folder until a private support
    /// channel exists (#204). Turn back on by setting this to true.
    static let githubIssuesEnabled = false

    /// The repos a developer can open an issue in.
    enum IssueRepo: String, CaseIterable, Identifiable {
        case macApp = "jonhanke-nam/PsyNeuView-MacApp"
        case psyNeuView = "jonhanke-nam/PsyNeuView"
        var id: String { rawValue }
        var title: String { self == .macApp ? "PsyNeuView-MacApp" : "PsyNeuView" }
    }

    /// A prefilled "new issue" link (developer mode only). GitHub can't take
    /// attachments through a link, so the body asks for the screenshot to be
    /// dragged in.
    static func issueURL(_ r: Request, repo: IssueRepo, home: String = NSHomeDirectory(),
                         maxLength: Int = maxURLLength) -> URL? {
        let first = redact(r.whatHappened, home: home)
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let title = "Problem report: " + (first.isEmpty ? r.reference : String(first.prefix(80)))
        var body = summary(r, home: home)
        body += "\n\nSaved report: `\(r.reference)` (in Downloads). "
            + "Drag the screenshot in here; GitHub links can't attach files."
        if r.included.contains(.logs), !r.logLines.isEmpty {
            let excerpt = redactedLog(Array(r.logLines.suffix(40)), home: home)
            body += "\n\n<details><summary>Last \(excerpt.count) log lines</summary>\n\n```\n"
                + excerpt.joined(separator: "\n") + "\n```\n</details>"
        }
        return link(
            "https://github.com/\(repo.rawValue)/issues/new",
            fields: [("title", title), ("body", body)], maxLength: maxLength,
            truncationNote: "_(Cut to fit a GitHub link. The full report is in \(r.reference).)_")
    }

    /// The first line of a report sent by a link or a fallback that can't
    /// attach files (#5). First, not last, so it's read and survives a cut.
    static func attachRequest(_ r: Request) -> String {
        "Please attach \(r.reference).zip before sending (it's selected in Finder, in your Downloads "
            + "folder). Without it the report has no logs or screenshot."
    }

    /// Kept for the Gmail callers and tests.
    static func gmailAttachRequest(_ r: Request) -> String { attachRequest(r) }

    private static func linkBody(_ r: Request, home: String) -> String {
        attachRequest(r) + "\n\n" + summary(r, home: home)
    }

    private static func cutNote(_ r: Request) -> String {
        "(Cut to fit a link. Please attach \(r.reference).zip from Downloads.)"
    }

    /// Gmail's web compose: the attach request first, then the summary.
    static func gmailURL(_ r: Request, to: String, home: String = NSHomeDirectory(),
                         maxLength: Int = maxURLLength) -> URL? {
        link(
            "https://mail.google.com/mail/",
            fields: [("view", "cm"), ("fs", "1"), ("to", to), ("su", emailSubject(r)), ("body", linkBody(r, home: home))],
            maxLength: maxLength, truncationNote: cutNote(r))
    }

    /// Outlook on the web's compose page, prefilled the same way.
    static func outlookWebURL(_ r: Request, to: String, home: String = NSHomeDirectory(),
                              maxLength: Int = maxURLLength) -> URL? {
        link(
            "https://outlook.office.com/mail/deeplink/compose",
            fields: [("to", to), ("subject", emailSubject(r)), ("body", linkBody(r, home: home))],
            maxLength: maxLength, truncationNote: cutNote(r))
    }

    /// A mailto link, for opening Outlook when it isn't the default mail app.
    static func mailtoURL(_ r: Request, to: String, home: String = NSHomeDirectory(),
                          maxLength: Int = maxURLLength) -> URL? {
        link(
            "mailto:" + to,
            fields: [("subject", emailSubject(r)), ("body", linkBody(r, home: home))],
            maxLength: maxLength, truncationNote: cutNote(r))
    }

    static func emailSubject(_ r: Request) -> String {
        "PsyNeuView problem report \(r.reference)"
    }

    /// The address to send to: the "Send to" setting, or the default
    /// contact when it's been cleared.
    static func contact(_ sendTo: String) -> String {
        let address = sendTo.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? ReportDefaults.contactEmail : address
    }

    /// What to tell the user after saving.
    static func sendInstructions(reference: String, sendTo: String) -> String {
        let who = contact(sendTo)
        return "Send the folder \(reference) (or \(reference).zip beside it) to the PsyNeuView team: "
            + "drag it into a Slack or Teams message, or attach it to an email to \(who)."
    }

    // MARK: Sending (#202)

    /// The "Send reports with" setting.
    enum SendWith: String, CaseIterable {
        case ask, mail, outlook, gmail

        init(setting: String) { self = SendWith(rawValue: setting) ?? .ask }
    }

    enum Route: Equatable {
        /// The share sheet. The file is handed over, but the target (a chat,
        /// a browser) may not keep it, so it's checked by hand.
        case share
        /// The default mail app, with the report attached by macOS.
        case email
        /// Gmail's web compose: a link, so no attachment.
        case gmail
        /// Outlook when it isn't the default mail app: opened on a mailto
        /// link, which can't carry an attachment.
        case outlookApp
        /// Outlook on the web: a link, so no attachment.
        case outlookWeb
    }

    /// What the window asks of the sender after a route is used (#5).
    enum AttachReminder: Equatable {
        case none
        /// Attached automatically: a short "check it's attached" line.
        case check
        /// Not attached: the file is selected in Finder and the window asks
        /// until the sender says it's done.
        case required
    }

    /// Which reminder a route needs. Only a mail app opened by macOS's
    /// sharing service attaches the file itself; every link and fallback
    /// needs the sender to attach it.
    static func attachReminder(after route: Route, setup: MailSetup) -> AttachReminder {
        switch route {
        case .email: return setup.defaultMailApp == nil ? .required : .check
        case .gmail, .outlookApp, .outlookWeb, .share: return .required
        }
    }

    /// What this Mac can send with.
    struct MailSetup: Equatable {
        /// Bundle id of the app that opens `mailto:` links, if any.
        var defaultMailApp: String?
        var outlookInstalled: Bool

        var defaultIsOutlook: Bool {
            defaultMailApp?.lowercased().hasPrefix("com.microsoft.outlook") ?? false
        }
    }

    struct SendPlan: Equatable {
        /// The way to lead with, when the setting picks one that works.
        var preferred: Route?
        /// Whether Email (attachments in the default mail app) can work.
        var emailAvailable: Bool
        /// Said when the chosen way isn't available, with the fallback.
        var notice: String?
    }

    static func sendPlan(_ with: SendWith, setup: MailSetup) -> SendPlan {
        let hasMail = setup.defaultMailApp != nil
        let fallback = " Use Share… or attach the folder yourself."
        switch with {
        case .ask:
            return SendPlan(
                preferred: nil, emailAvailable: hasMail,
                notice: hasMail ? nil : "Email isn't offered: no mail app is set up on this Mac.")
        case .mail:
            guard hasMail else {
                return SendPlan(
                    preferred: nil, emailAvailable: false,
                    notice: "Reports are set to go by email, but no mail app is set up on this Mac." + fallback)
            }
            return SendPlan(preferred: .email, emailAvailable: true, notice: nil)
        case .outlook:
            if setup.defaultIsOutlook {
                return SendPlan(preferred: .email, emailAvailable: true, notice: nil)
            }
            // Outlook without automatic attaching (#5): open it anyway (the
            // app on a mailto link, or Outlook on the web) and have the sender
            // attach the file, which is selected in Finder.
            let attach = " Outlook opens with the message; drag the report's file in from Finder."
            if setup.outlookInstalled {
                return SendPlan(
                    preferred: .outlookApp, emailAvailable: hasMail,
                    notice: "Outlook isn't your default mail app, so the report can't be attached there automatically." + attach)
            }
            return SendPlan(
                preferred: .outlookWeb, emailAvailable: hasMail,
                notice: "Reports are set to go by Outlook, but Outlook isn't installed on this Mac, so Outlook on the web is used." + attach)
        case .gmail:
            return SendPlan(preferred: .gmail, emailAvailable: hasMail, notice: nil)
        }
    }

    // MARK: Helpers

    /// "1 line", "2 lines".
    static func counted(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)" + (n == 1 ? "" : "s")
    }

    private static func capped(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxDescriptionLength else { return t }
        return String(t.prefix(maxDescriptionLength)) + " … [cut at \(maxDescriptionLength) characters]"
    }

    private static func redacted(_ f: Facts, home: String) -> Facts {
        let r = { (s: String) in redact(s, home: home) }
        var c = f
        c.appVersion = r(f.appVersion)
        c.appBuild = f.appBuild.map(r)
        c.psyNeuViewVersion = f.psyNeuViewVersion.map(r)
        c.install = r(f.install)
        c.psyNeuLinkSource = r(f.psyNeuLinkSource)
        c.psyNeuLinkVersion = f.psyNeuLinkVersion.map(r)
        c.server = r(f.server)
        c.startupOutcome = f.startupOutcome.map(r)
        c.moveOutcome = f.moveOutcome.map(r)
        c.settingsSupport = f.settingsSupport.map(r)
        c.steps = f.steps.map { Step(title: r($0.title), status: r($0.status)) }
        c.macOSVersion = r(f.macOSVersion)
        c.macModel = r(f.macModel)
        c.pagePreferenceKeys = f.pagePreferenceKeys.map(r)
        return c
    }

    private static func versionLines(_ f: Facts) -> [String] {
        [
            "PsyNeuView app: \(f.appVersion)" + (f.appBuild.map { " (build \($0))" } ?? ""),
            "PsyNeuView: \(f.psyNeuViewVersion ?? "unknown")",
            "Runs from: \(f.install)",
            "App's Settings: \(f.settingsSupport ?? "not checked")",
            "PsyNeuLink: \(f.psyNeuLinkVersion ?? "unknown"), from \(f.psyNeuLinkSource)",
            "Developer mode: \(f.developerMode ? "on" : "off")",
            pagePreferencesLine(f.pagePreferenceKeys),
        ]
    }

    /// "Page preferences kept by the app: 3 (a, b, c)" — names only.
    static func pagePreferencesLine(_ keys: [String]) -> String {
        guard !keys.isEmpty else { return "Page preferences kept by the app: none" }
        return "Page preferences kept by the app: \(keys.count) (\(keys.joined(separator: ", ")))"
    }

    private static func startupLines(_ f: Facts) -> [String] {
        [
            "Server: \(f.server)",
            "This launch: \(f.startupOutcome ?? "nothing recorded")",
            "Move to the included PsyNeuView (#186): \(f.moveOutcome ?? "none tried")",
        ]
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f.string(from: date)
    }
}
