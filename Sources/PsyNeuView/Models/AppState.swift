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

    @discardableResult
    func addLog(_ text: String, source: LogSource, isError: Bool = false) -> UUID {
        let entry = LogEntry(source: source, text: text, isError: isError)
        logs.append(entry)
        if logs.count > Constants.maxLogLines {
            logs.removeFirst(logs.count - Constants.maxLogLines)
        }
        return entry.id
    }

    /// Change the text of a row already in the window, such as a package
    /// count that grows (#75). False when the row is gone (cleared or trimmed).
    @discardableResult
    func replaceLog(id: UUID, text: String) -> Bool {
        guard let index = logs.lastIndex(where: { $0.id == id }) else { return false }
        logs[index] = logs[index].replacingText(text)
        return true
    }

    func clearLogs() {
        logs.removeAll()
    }
}
