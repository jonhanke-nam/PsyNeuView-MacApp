import Foundation

@Observable
final class AppState {
    var backendStatus: ServerStatus = .stopped
    var repoPath: URL?
    var logs: [LogEntry] = []
    var backendPort: Int = 0

    var overallStatus: ServerStatus {
        backendStatus
    }

    var isRunning: Bool {
        backendStatus == .running
    }

    var canStart: Bool {
        backendStatus == .stopped
    }

    var canStop: Bool {
        backendStatus != .stopped
    }

    func addLog(_ text: String, source: LogSource, isError: Bool = false) {
        let entry = LogEntry(source: source, text: text, isError: isError)
        logs.append(entry)
        if logs.count > Constants.maxLogLines {
            logs.removeFirst(logs.count - Constants.maxLogLines)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }
}
