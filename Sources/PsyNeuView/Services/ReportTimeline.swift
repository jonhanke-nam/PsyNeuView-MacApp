import Foundation

/// `timeline.txt` in a problem report (PsyNeuView#177): the page's timeline
/// — what the user did, what the app did, errors, messages and every wait's
/// start and stop — merged with this launch's server log, in time order,
/// each line marked with its source, in one time format.
///
/// The page's times are UTC (ISO); the launch log's are local
/// (`[2026-11-03 09:14:19.779] [Backend] …`, LaunchLog.formatLine). Both
/// are read into Dates and written back in local time, with the zone named
/// in the header. The page and the server run on the same Mac, so their
/// clocks agree once the formats do.
///
/// Routine lines — the health check — are left out here; `logs.txt` keeps
/// every line. A log line without a time of its own (the rest of a
/// traceback) keeps the time of the line before it, so it stays with it.
enum ReportTimeline {

    /// Lines kept at most, the latest; a report shouldn't be swamped.
    static let maxLines = 20_000

    /// The log's source tag, as `timeline.txt` marks a server line.
    static let serverSource = "server"

    struct Line: Equatable {
        var time: Date
        var source: String
        var text: String
    }

    // MARK: The launch log

    private static let logLine = try! NSRegularExpression(
        pattern: #"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\] \[([^\]]+)\]( \[error\])? ?(.*)$"#)

    /// A line is routine when it is the health check the app polls with.
    static func isRoutine(_ text: String) -> Bool {
        text.contains("GET /health ") || text.contains("GET /health\"") || text.hasSuffix("GET /health")
            || text.contains("/health HTTP/")
    }

    static func logFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }

    /// One launch-log line as a timeline line: its time read in `timeZone`,
    /// its source and `[error]` kept in the text. Nil when the line has no
    /// time stamp of its own.
    static func parseLogLine(_ line: String, formatter: DateFormatter) -> Line? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = logLine.firstMatch(in: line, range: range),
              let stampRange = Range(m.range(at: 1), in: line),
              let sourceRange = Range(m.range(at: 2), in: line),
              let textRange = Range(m.range(at: 4), in: line),
              let time = formatter.date(from: String(line[stampRange])) else { return nil }
        let isError = m.range(at: 3).location != NSNotFound
        let source = String(line[sourceRange])
        let text = String(line[textRange])
        return Line(time: time, source: serverSource, text: "\(source)\(isError ? " [error]" : "") · \(text)")
    }

    /// The launch log as timeline lines, routine lines left out, a line
    /// without a stamp kept with the one before it.
    static func serverLines(_ log: [String], timeZone: TimeZone = .current) -> [Line] {
        let formatter = logFormatter(timeZone)
        var out: [Line] = []
        var skipping = false
        for raw in log {
            let line = raw.trimmingCharacters(in: .newlines)
            if line.isEmpty { continue }
            if let parsed = parseLogLine(line, formatter: formatter) {
                skipping = isRoutine(parsed.text)
                if !skipping { out.append(parsed) }
            } else if let last = out.last, !skipping {
                out.append(Line(time: last.time, source: serverSource, text: "  " + line))
            }
        }
        return out
    }

    // MARK: Merging

    static func pageLines(_ entries: [PageDiagnostics.TimelineEntry]) -> [Line] {
        entries.map { Line(time: $0.time, source: $0.source, text: $0.text) }
    }

    /// The page's lines and the server's in time order; at the same instant,
    /// the page's first, then the log's, each in its own order.
    static func merged(page: [Line], server: [Line]) -> [Line] {
        let all = page.enumerated().map { ($0.element, 0, $0.offset) }
            + server.enumerated().map { ($0.element, 1, $0.offset) }
        return all.sorted { a, b in
            if a.0.time != b.0.time { return a.0.time < b.0.time }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }.map(\.0)
    }

    // MARK: The file

    /// `2026-11-03 09:15:04.850  action   Open menu opened`.
    static func format(_ line: Line, formatter: DateFormatter) -> String {
        let source = line.source.padding(toLength: max(7, line.source.count), withPad: " ", startingAt: 0)
        return "\(formatter.string(from: line.time))  \(source)  \(line.text)"
    }

    /// The header says what the file is and which clock it uses, so a file
    /// read on its own still makes sense.
    static func header(timeZone: TimeZone, serverLines: Int, pageLines: Int) -> [String] {
        let name = timeZone.identifier
        let offset = timeZone.secondsFromGMT()
        let sign = offset < 0 ? "-" : "+"
        let hh = String(format: "%02d", abs(offset) / 3600)
        let mm = String(format: "%02d", abs(offset) % 3600 / 60)
        var lines = [
            "# PsyNeuView timeline: what the user did, what the app did, errors, waits and the server log, in time order.",
            "# Times are local to this Mac: \(name) (UTC\(sign)\(hh):\(mm)). "
                + "Sources: action · event · error · message · wait · page · server.",
        ]
        if serverLines == 0 {
            lines.append("# No server log lines: the server log wasn't included, or had nothing but routine lines.")
        } else {
            lines.append("# Routine server lines (the health check) are left out; logs.txt has every line.")
        }
        if pageLines == 0 {
            lines.append("# No lines from PsyNeuView's page: it didn't provide a timeline (older version or not loaded).")
        }
        return lines
    }

    /// The whole file, redacted like the rest of the report.
    static func text(
        page: [PageDiagnostics.TimelineEntry],
        log: [String],
        timeZone: TimeZone = .current,
        home: String = NSHomeDirectory()
    ) -> String {
        let pageLines = pageLines(page)
        let server = serverLines(log, timeZone: timeZone)
        var lines = merged(page: pageLines, server: server)
        var note: String? = nil
        if lines.count > maxLines {
            note = "[… the earliest \(lines.count - maxLines) lines were left out]"
            lines = Array(lines.suffix(maxLines))
        }
        let formatter = logFormatter(timeZone)
        var out = header(timeZone: timeZone, serverLines: server.count, pageLines: pageLines.count)
        if let note { out.append(note) }
        out.append(contentsOf: lines.map { ProblemReport.redact(format($0, formatter: formatter), home: home) })
        return out.joined(separator: "\n") + "\n"
    }
}
