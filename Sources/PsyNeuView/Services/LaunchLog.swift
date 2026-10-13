import Foundation

/// Each launch's log, written to a file as it happens (#208).
///
///     ~/Library/Logs/PsyNeuView/launch-2026-10-09_14-03-22.log
///
/// The Logs window shows the in-memory log, which is capped at
/// `Constants.maxLogLines` and gone when the app quits. Report a Problem
/// attaches the whole launch instead: every line since the app started, from
/// this file. The last `keepLaunches` launches are kept, so a report made
/// right after a failed start can carry the launch that failed. One file is
/// capped at `maxBytes`; past that, the earliest lines are dropped and a note
/// at the top says how many.
///
/// The rules — names, which files to keep, the line format, the cap — are
/// pure functions here, tested directly. `LaunchLogWriter` does the I/O.
enum LaunchLog {

    static let keepLaunches = 5
    static let maxBytes = 5 * 1024 * 1024
    /// After a trim the file is this big, so one line over the cap doesn't
    /// mean rewriting the file for every line that follows.
    static let trimTargetBytes = maxBytes * 3 / 4

    static let filePrefix = "launch-"
    static let fileSuffix = ".log"
    static let notePrefix = "[… "

    /// `~/Library/Logs/PsyNeuView`, the folder Console's Log Reports lists;
    /// `PsyNeuView-Test` for the test app (#209).
    static var directory: URL {
        AppIdentity.current.logsDirectory()
    }

    // MARK: Names

    /// `launch-2026-10-09_14-03-22.log`, in local time: sorts by time and
    /// has no colons (Finder won't take them).
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return filePrefix + f.string(from: date) + fileSuffix
    }

    static func isLaunchLog(_ name: String) -> Bool {
        name.hasPrefix(filePrefix) && name.hasSuffix(fileSuffix) && name.count > filePrefix.count + fileSuffix.count
    }

    /// The launch logs among `names`, oldest first. The names sort by time.
    static func launchLogs(in names: [String]) -> [String] {
        names.filter(isLaunchLog).sorted()
    }

    /// The newest existing launch log: the previous launch's.
    static func previous(in names: [String]) -> String? {
        launchLogs(in: names).last
    }

    /// Which existing logs to delete before this launch's is added, so that
    /// at most `keep` remain afterwards: the oldest ones.
    static func namesToRemove(existing names: [String], keep: Int = keepLaunches) -> [String] {
        let logs = launchLogs(in: names)
        let room = max(0, keep - 1)
        guard logs.count > room else { return [] }
        return Array(logs.prefix(logs.count - room))
    }

    // MARK: Lines

    /// `[2026-10-09 14:03:22.123] [System] [error] text`. A full date, unlike
    /// the Logs window's time of day, because the file may be read days
    /// later next to another launch's.
    static func formatLine(date: Date, source: LogSource, text: String, isError: Bool,
                           timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return "[\(f.string(from: date))] [\(source.rawValue)]" + (isError ? " [error]" : "") + " " + text
    }

    /// The first line of this launch's file: says which launch it is, so a
    /// file found on its own still makes sense.
    static func header(appVersion: String, date: Date, timeZone: TimeZone = .current,
                       identity: AppIdentity = .current) -> String {
        formatLine(date: date, source: .system,
                   text: "\(identity.displayName) app \(appVersion) launched; this file is the whole launch's log",
                   isError: false, timeZone: timeZone)
    }

    // MARK: The size cap

    /// Bytes the lines take in the file: each with its newline.
    static func bytes(of lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    static func droppedNote(lines: Int, maxBytes: Int = maxBytes) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.locale = Locale(identifier: "en_US")  // "1,234" on every Mac; en_US_POSIX has no grouping
        n.usesGroupingSeparator = true
        let count = n.string(from: NSNumber(value: lines)) ?? String(lines)
        let mb = maxBytes / (1024 * 1024)
        return notePrefix + "the earliest \(count) line\(lines == 1 ? "" : "s") of this launch were dropped "
            + "to keep this file under \(mb) MB]"
    }

    struct Trimmed: Equatable {
        var lines: [String]
        /// Lines dropped from this launch so far, the earlier note included.
        var dropped: Int
    }

    /// The file's lines after a trim: oldest first out, until it is under
    /// `targetBytes`, with one note at the top counting everything dropped so
    /// far. Lines the file already lost (an earlier note) are counted in.
    /// Unchanged when it fits in `maxBytes`.
    static func trim(_ lines: [String], droppedBefore: Int = 0,
                     maxBytes: Int = maxBytes, targetBytes: Int = trimTargetBytes) -> Trimmed {
        var body = lines
        var dropped = droppedBefore
        if let first = body.first, first.hasPrefix(notePrefix) {
            body.removeFirst()
            if droppedBefore == 0 { dropped = droppedCount(in: first) }
        }
        guard bytes(of: lines) > maxBytes else { return Trimmed(lines: lines, dropped: dropped) }
        var size = bytes(of: body)
        // Leave room for the note.
        let budget = targetBytes - 160
        while size > budget, let first = body.first {
            body.removeFirst()
            size -= first.utf8.count + 1
            dropped += 1
        }
        return Trimmed(lines: [droppedNote(lines: dropped, maxBytes: maxBytes)] + body, dropped: dropped)
    }

    /// The count in a note written by `droppedNote`, or 0.
    static func droppedCount(in note: String) -> Int {
        guard let range = note.range(of: #"earliest ([0-9,]+) line"#, options: .regularExpression) else { return 0 }
        let digits = note[range].filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

/// Writes one launch's log file as lines arrive, and reads it and the
/// previous launch's back for Report a Problem. Used from the main actor,
/// where `LogCollector` runs; a write is one `FileHandle` call, so a line is
/// on disk before the next thing happens, which is what a crash needs.
final class LaunchLogWriter {
    let directory: URL
    /// This launch's file.
    let fileURL: URL
    /// The newest launch log that was there before this launch, if any.
    let previousFileURL: URL?
    private let maxBytes: Int
    private let targetBytes: Int
    private var handle: FileHandle?
    /// Bytes written since the last trim, or since opening.
    private(set) var bytes = 0
    private(set) var dropped = 0
    /// Why writing isn't happening, when it isn't; for the log.
    private(set) var failure: String?

    init(directory: URL = LaunchLog.directory, date: Date = Date(),
         appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
         keep: Int = LaunchLog.keepLaunches,
         maxBytes: Int = LaunchLog.maxBytes, targetBytes: Int = LaunchLog.trimTargetBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.targetBytes = targetBytes
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        previousFileURL = LaunchLog.previous(in: existing).map { directory.appendingPathComponent($0) }
        for name in LaunchLog.namesToRemove(existing: existing, keep: keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        var name = LaunchLog.fileName(for: date)
        if fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = String(name.dropLast(LaunchLog.fileSuffix.count)) + "-\(ProcessInfo.processInfo.processIdentifier)"
                + LaunchLog.fileSuffix
        }
        fileURL = directory.appendingPathComponent(name)
        let header = LaunchLog.header(appVersion: appVersion, date: date) + "\n"
        do {
            try Data(header.utf8).write(to: fileURL, options: .atomic)
            handle = try FileHandle(forWritingTo: fileURL)
            try handle?.seekToEnd()
            bytes = header.utf8.count
        } catch {
            handle = nil
            failure = "Couldn't write the launch log at \(fileURL.path): \(error.localizedDescription)"
        }
    }

    deinit {
        try? handle?.close()
    }

    func append(source: LogSource, text: String, isError: Bool, at date: Date = Date()) {
        guard let handle else { return }
        let line = LaunchLog.formatLine(date: date, source: source, text: text, isError: isError) + "\n"
        do {
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            return
        }
        bytes += line.utf8.count
        if bytes > maxBytes { trimFile() }
    }

    /// Rewrite the file without its earliest lines (`LaunchLog.trim`).
    private func trimFile() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines.last == "" ? Array(lines.dropLast()) : lines
        let trimmed = LaunchLog.trim(body, droppedBefore: dropped, maxBytes: maxBytes, targetBytes: targetBytes)
        dropped = trimmed.dropped
        let joined = trimmed.lines.joined(separator: "\n") + "\n"
        do {
            try handle?.close()
            try Data(joined.utf8).write(to: fileURL, options: .atomic)
            handle = try FileHandle(forWritingTo: fileURL)
            try handle?.seekToEnd()
            bytes = joined.utf8.count
        } catch {
            handle = nil
            failure = "Couldn't rewrite the launch log: \(error.localizedDescription)"
        }
    }

    /// Every line of this launch so far.
    func currentLines() -> [String] {
        Self.lines(of: fileURL) ?? []
    }

    /// Every line of the previous launch, or nil when there is no such file.
    func previousLines() -> [String]? {
        previousFileURL.flatMap(Self.lines(of:))
    }

    private static func lines(of url: URL) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .reversed().drop(while: \.isEmpty).reversed()
    }
}
