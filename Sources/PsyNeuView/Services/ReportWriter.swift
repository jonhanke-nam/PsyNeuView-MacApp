import Foundation

/// Saves a problem report (#202): a folder, and a .zip of it beside it.
///
///     <destination>/PNV-debugging-2026-10-06_14-03-22/
///         report.md  screenshot-1.png …  logs.txt  logs-previous-launch.txt
///         page-state.json  activity.txt  diagnostics.json
///     <destination>/PNV-debugging-2026-10-06_14-03-22.zip
///
/// The destination is ~/Downloads in the app and a temporary folder in tests.
enum ReportWriter {

    struct Screenshot: Equatable {
        /// "screenshot-1.png"
        var name: String
        var png: Data
    }

    struct Saved: Equatable {
        var folder: URL
        /// Nil when zipping failed; the folder is still there.
        var zip: URL?
        /// Every file in the folder, in the order written.
        var files: [URL]
    }

    enum WriteError: LocalizedError {
        case cannotCreate(String)
        var errorDescription: String? {
            switch self {
            case .cannotCreate(let detail): return "Couldn't save the report: \(detail)"
            }
        }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// A folder name not already taken: the reference, or `-2`, `-3`… when
    /// two reports are saved within the same second.
    static func freeName(_ reference: String, in destination: URL,
                         fm: FileManager = .default) -> String {
        var name = reference
        var n = 2
        while fm.fileExists(atPath: destination.appendingPathComponent(name).path)
                || fm.fileExists(atPath: destination.appendingPathComponent(name + ".zip").path) {
            name = "\(reference)-\(n)"
            n += 1
        }
        return name
    }

    static func save(
        reference: String,
        files: ProblemReport.Files,
        screenshots: [Screenshot],
        into destination: URL,
        zip: Bool = true
    ) throws -> Saved {
        let fm = FileManager.default
        let name = freeName(reference, in: destination, fm: fm)
        let folder = destination.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw WriteError.cannotCreate(error.localizedDescription)
        }

        var written: [URL] = []
        func write(_ data: Data, _ file: String) throws {
            let url = folder.appendingPathComponent(file)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw WriteError.cannotCreate(error.localizedDescription)
            }
            written.append(url)
        }
        try write(Data(files.markdown.utf8), "report.md")
        for shot in screenshots { try write(shot.png, shot.name) }
        if let logs = files.logs { try write(Data(logs.utf8), ProblemReport.Part.logs.fileName!) }
        if let previous = files.previousLogs {
            try write(Data(previous.utf8), ProblemReport.Part.previousLogs.fileName!)
        }
        if let state = files.pageState { try write(Data(state.utf8), ProblemReport.Part.pageState.fileName!) }
        if let activity = files.pageActivity {
            try write(Data(activity.utf8), ProblemReport.Part.pageActivity.fileName!)
        }
        try write(files.diagnostics, "diagnostics.json")

        let zipURL = zip ? makeZip(of: folder) : nil
        return Saved(folder: folder, zip: zipURL, files: written)
    }

    /// `ditto -c -k --keepParent`, as Finder's Compress does: one file that
    /// unpacks to the folder. Nil when it fails; the folder alone still works.
    static func makeZip(of folder: URL) -> URL? {
        let zip = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: zip.path) ? zip : nil
    }
}
