import Foundation

@MainActor
final class LogCollector {
    private let appState: AppState
    /// This launch's log file (#208): every line goes there too, so Report a
    /// Problem can attach the whole launch rather than what the window kept.
    var launchLog: LaunchLogWriter?

    init(appState: AppState) {
        self.appState = appState
    }

    /// The package list being counted into one row (#75): its source, its
    /// count so far, and the row that shows the count.
    private var packageRun: (source: LogSource, summary: PackageListSummary, row: UUID)?

    func add(_ text: String, source: LogSource, isError: Bool = false) {
        // Split multiline output into individual entries
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            showInWindow(trimmed, source: source, isError: isError)
            // Every line, package lines too: Report a Problem attaches this.
            launchLog?.append(source: source, text: trimmed, isError: isError)
            // Unattended, the log window has no reader. Mirror it to stderr so
            // a launch check that fails can say why (#174).
            if AppRelocation.isNonInteractive {
                FileHandle.standardError.write(Data("[\(source)] \(trimmed)\n".utf8))
            }
        }
    }

    /// Add a line to the window, counting a run of uv's package lines into
    /// one row instead of a row each (#75).
    private func showInWindow(_ line: String, source: LogSource, isError: Bool) {
        if !isError, PackageListSummary.change(in: line) != nil {
            if var run = packageRun, run.source == source {
                _ = run.summary.absorb(line)
                packageRun = run
                if appState.replaceLog(id: run.row, text: run.summary.text) { return }
                // The row was cleared away: start a new one with the count so far.
                packageRun?.row = appState.addLog(run.summary.text, source: source)
                return
            }
            var summary = PackageListSummary()
            _ = summary.absorb(line)
            packageRun = (source, summary, appState.addLog(summary.text, source: source))
            return
        }
        packageRun = nil
        appState.addLog(line, source: source, isError: isError)
    }
}
