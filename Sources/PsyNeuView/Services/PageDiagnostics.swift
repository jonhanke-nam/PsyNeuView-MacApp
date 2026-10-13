import Foundation

/// PsyNeuView's own diagnostics, when the page provides them (#208; the
/// page side is PsyNeuView-archive#1287).
///
/// The contract: the page defines `window.__pnvDiagnostics`, an async
/// function returning `{ version: 1, state: {...}, activity: [...] }`. When a
/// report is made and an app window's page is loaded, the app calls it with
/// `callAsyncJavaScript` and waits up to `timeout`. Whatever comes back —
/// null, an error, nothing in time, an older page without the function —
/// the report goes on; it just says PsyNeuView didn't provide its
/// diagnostics.
///
/// What's attached: `page-state.json` (the state, pretty-printed and
/// redacted) and `activity.txt` (one line per entry: time · kind · text).
/// The parsing and formatting are pure, so they are tested from sample
/// values without a web view.
enum PageDiagnostics {

    /// What the app runs in the page. `return await` so a page without the
    /// function answers `null` rather than throwing.
    static let script = "return await (window.__pnvDiagnostics ? window.__pnvDiagnostics() : null)"

    static let timeout: TimeInterval = 3

    static let notProvidedNote = "PsyNeuView didn't provide its diagnostics (older version or not loaded)."

    /// `page-state.json` is capped so a runaway state can't swamp the report.
    static let maxStateBytes = 1024 * 1024
    static let maxActivityLines = 10_000

    /// What the page gave, already in the report's shapes.
    struct Provided: Equatable {
        var version: Int
        /// The state, pretty-printed JSON.
        var stateJSON: String
        /// One line per activity entry.
        var activityLines: [String]
    }

    enum Outcome: Equatable {
        case provided(Provided)
        /// Why there is nothing: the user's note in the report.
        case notProvided(String)

        var provided: Provided? {
            if case .provided(let p) = self { return p }
            return nil
        }

        var note: String {
            switch self {
            case .provided: return ""
            case .notProvided(let why): return why
            }
        }
    }

    // MARK: Reading the answer

    /// The outcome for what `callAsyncJavaScript` gave back: its result or
    /// its error. Strict about the shape; anything else is "not provided",
    /// with the reason after the standard note.
    static func outcome(result: Any?, error: Error?) -> Outcome {
        if let error {
            return .notProvided(notProvidedNote + " The page answered with an error: \(error.localizedDescription)")
        }
        guard let result, !(result is NSNull) else {
            return .notProvided(notProvidedNote)
        }
        guard let dict = result as? [String: Any] else {
            return .notProvided(notProvidedNote + " The page's answer wasn't an object.")
        }
        let version = (dict["version"] as? NSNumber)?.intValue ?? (dict["version"] as? Int) ?? 0
        guard version >= 1 else {
            return .notProvided(notProvidedNote + " The page's answer had no version.")
        }
        let state = dict["state"] ?? NSNull()
        let activity = dict["activity"] as? [Any] ?? []
        return .provided(Provided(
            version: version,
            stateJSON: stateJSON(state),
            activityLines: activityLines(activity)))
    }

    /// Nothing came back within `timeout`.
    static func timedOut() -> Outcome {
        .notProvided(notProvidedNote + " It didn't answer within \(Int(timeout)) seconds.")
    }

    /// No app window, or its page isn't loaded.
    static func noPage() -> Outcome {
        .notProvided(notProvidedNote + " No app window had a page loaded.")
    }

    // MARK: Shapes

    /// The state as pretty-printed JSON, keys sorted, capped at
    /// `maxStateBytes` with a note. Values JSON can't carry (a Date, say)
    /// are described.
    static func stateJSON(_ state: Any) -> String {
        let object = jsonSafe(state)
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        var text = data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
        if text.utf8.count > maxStateBytes {
            text = String(text.prefix(maxStateBytes)) + "\n… [cut at \(maxStateBytes / 1024) KB]"
        }
        return text
    }

    /// `time · kind · text`, one per entry, in the order given. A field
    /// that's missing is `?`; an entry that isn't an object is shown as is.
    /// Capped at `maxActivityLines`, keeping the latest.
    static func activityLines(_ activity: [Any]) -> [String] {
        var lines = activity.map { entry -> String in
            guard let e = entry as? [String: Any] else { return "? · ? · " + describe(entry) }
            return [field(e, "time"), field(e, "kind"), field(e, "text")].joined(separator: " · ")
        }
        if lines.count > maxActivityLines {
            let dropped = lines.count - maxActivityLines
            lines = ["[… the earliest \(dropped) entries were left out]"] + lines.suffix(maxActivityLines)
        }
        return lines
    }

    /// The report's `activity.txt`, redacted.
    static func activityText(_ lines: [String], home: String = NSHomeDirectory()) -> String {
        guard !lines.isEmpty else { return "(no activity recorded)\n" }
        return lines.map { ProblemReport.redact($0, home: home) }.joined(separator: "\n") + "\n"
    }

    private static func field(_ e: [String: Any], _ key: String) -> String {
        guard let v = e[key], !(v is NSNull) else { return "?" }
        if key == "time", let n = v as? NSNumber, !(v is Bool) {
            return isoTime(n.doubleValue)
        }
        return describe(v).replacingOccurrences(of: "\n", with: " ")
    }

    /// A number as the page's `Date.now()` (milliseconds) or seconds, in UTC.
    static func isoTime(_ value: Double) -> String {
        // Past the year 3000 as seconds, it's milliseconds.
        let seconds = value > 32_503_680_000 ? value / 1000 : value
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func describe(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull: return "null"
        default:
            if let data = try? JSONSerialization.data(withJSONObject: jsonSafe(v), options: [.sortedKeys, .fragmentsAllowed]) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: v)
        }
    }

    /// Only what JSONSerialization accepts; anything else becomes its
    /// description.
    private static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        case let n as NSNumber:
            // NaN and infinity aren't JSON.
            let x = n.doubleValue
            return x.isNaN || x.isInfinite ? String(describing: x) : n
        case is String, is NSNull: return v
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        default: return String(describing: v)
        }
    }
}
