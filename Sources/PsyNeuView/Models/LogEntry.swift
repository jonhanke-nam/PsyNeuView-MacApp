import Foundation

enum LogSource: String, CaseIterable, Sendable {
    case backend = "Backend"
    case frontend = "Frontend"
    /// What setup and update runs print: uv, pip, git, npm (#75). It was
    /// labelled System, which read as the launcher's own messages.
    case installer = "Installer"
    case system = "System"
}

struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let source: LogSource
    let text: String
    let isError: Bool

    init(source: LogSource, text: String, isError: Bool = false) {
        self.id = UUID()
        self.timestamp = Date()
        self.source = source
        self.text = text
        self.isError = isError
    }

    /// The same row with new text: same place, same time (#75).
    func replacingText(_ text: String) -> LogEntry {
        LogEntry(id: id, timestamp: timestamp, source: source, text: text, isError: isError)
    }

    private init(id: UUID, timestamp: Date, source: LogSource, text: String, isError: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.text = text
        self.isError = isError
    }

    var formattedTimestamp: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
