import Foundation

/// One phase of the backend's own start, as it reports it (#232).
///
/// The backend prints a line to its standard output as each phase begins
/// and ends:
///
///     PNV-START <phase> <event> [elapsed=<seconds>] [detail=<url-encoded>]
///
/// with `event` one of `begin`, `end` or `skip`, and the phases in this
/// order: `migrate`, `pnl-update`, `import-psyneulink`, `warm-worker`,
/// `ready` (whose `end` carries the whole start as `elapsed`). The app
/// turns these into checklist steps: "Loading PsyNeuLink" is a real step
/// with its own clock rather than part of one long "starting".
///
/// Backends older than this contract print nothing of the kind, and the
/// checklist falls back to one "Starting the server" step that covers
/// everything until /health. A line this parser can't read is ignored the
/// same way — nothing here can break a start.
struct StartPhase: Equatable, Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case migrate
        case pnlUpdate = "pnl-update"
        case importPsyNeuLink = "import-psyneulink"
        case warmWorker = "warm-worker"
        case ready
    }

    enum Event: String, Sendable {
        case begin, end, skip
    }

    var phase: Phase
    var event: Event
    /// Seconds the phase took, from the backend's own clock, on `end`.
    var elapsed: Double?
    /// A word about it, decoded: why it was skipped, which version was
    /// installed.
    var detail: String?

    static let marker = "PNV-START"

    /// The phase a line reports, or nil for any other line — including a
    /// marker line with a phase or event this app doesn't know, which a newer
    /// backend may well print.
    static func parse(_ raw: String) -> StartPhase? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // uvicorn may prefix nothing, but a logger could; anchor on the marker
        // wherever it starts, as long as it starts a word.
        guard let markerRange = line.range(of: marker) else { return nil }
        if markerRange.lowerBound > line.startIndex {
            let before = line[line.index(before: markerRange.lowerBound)]
            guard before == " " || before == "\t" else { return nil }
        }
        let words = line[markerRange.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard words.count >= 2,
              let phase = Phase(rawValue: words[0]),
              let event = Event(rawValue: words[1]) else { return nil }

        var elapsed: Double?
        var detail: String?
        for word in words.dropFirst(2) {
            guard let eq = word.firstIndex(of: "=") else { continue }
            let key = word[..<eq]
            let value = String(word[word.index(after: eq)...])
            switch key {
            case "elapsed":
                if let seconds = Double(value), seconds.isFinite, seconds >= 0 { elapsed = seconds }
            case "detail":
                let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
                if !decoded.isEmpty { detail = decoded }
            default:
                break
            }
        }
        return StartPhase(phase: phase, event: event, elapsed: elapsed, detail: detail)
    }

    /// The checklist step a phase belongs to (#232): the first two are part
    /// of starting the server — the PsyNeuLink update becomes a step of its
    /// own only once it begins — and `ready` closes whatever is running.
    var step: ProgressStep? {
        switch phase {
        case .migrate: return .startServer
        case .pnlUpdate: return .installPsyNeuLinkUpdate
        case .importPsyNeuLink: return .loadPsyNeuLink
        case .warmWorker: return .warmModelRunner
        case .ready: return nil
        }
    }

    /// Plain words for the report: "backend: import-psyneulink".
    var title: String { "backend: \(phase.rawValue)" }
}

/// Splits a stream read in chunks into lines, keeping a partial last line
/// for the next chunk. A pipe hands the reader whatever is there, which can
/// end mid-line; a marker line split in two would be read as neither half.
struct LineSplitter {
    private var partial = ""

    /// The complete lines in `chunk`, with any unfinished tail kept back.
    mutating func lines(from chunk: String) -> [String] {
        var buffer = partial + chunk
        partial = ""
        var out: [String] = []
        while let end = buffer.firstIndex(where: { $0.isNewline }) {  // "\r\n" is one Character in Swift
            out.append(String(buffer[..<end]))
            buffer = String(buffer[buffer.index(after: end)...])
        }
        partial = buffer
        return out
    }

    /// Whatever is left when the stream ends.
    mutating func flush() -> String? {
        defer { partial = "" }
        return partial.isEmpty ? nil : partial
    }
}
