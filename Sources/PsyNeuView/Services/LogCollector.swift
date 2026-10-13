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

    func add(_ text: String, source: LogSource, isError: Bool = false) {
        // Split multiline output into individual entries
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            appState.addLog(trimmed, source: source, isError: isError)
            launchLog?.append(source: source, text: trimmed, isError: isError)
            // Unattended, the log window has no reader. Mirror it to stderr so
            // a launch check that fails can say why (#174).
            if AppRelocation.isNonInteractive {
                FileHandle.standardError.write(Data("[\(source)] \(trimmed)\n".utf8))
            }
        }
    }
}
