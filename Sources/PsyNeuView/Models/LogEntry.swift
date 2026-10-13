import Foundation

enum LogSource: String, CaseIterable, Sendable {
    case backend = "Backend"
    case frontend = "Frontend"
    case system = "System"
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let source: LogSource
    let text: String
    let isError: Bool

    init(source: LogSource, text: String, isError: Bool = false) {
        self.timestamp = Date()
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
