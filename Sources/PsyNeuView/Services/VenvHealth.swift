import Foundation

/// What `pyvenv.cfg` records about the interpreter a virtual environment was
/// built from.
///
/// A venv is not relocatable: it stores the absolute path of its base
/// interpreter and cannot outlive it. Now that the interpreter ships inside the
/// app bundle (#64), Sparkle replacing that bundle can invalidate every venv on
/// the machine — the runtime directory is version-stamped
/// (`Resources/python-3.14.7/`), so a patch bump moves the path.
///
/// Observed rather than assumed: a venv built from the bundled runtime records
///
///     home = /Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin
///     version = 3.14.7
///
/// (#66, under #26)
struct VenvRecord: Equatable, Sendable {
    /// The `bin` directory of the interpreter the venv was built from.
    let home: String
    /// The interpreter version, when recorded.
    let version: String?

    /// Parse the `key = value` lines of a `pyvenv.cfg`.
    static func parse(_ contents: String) -> VenvRecord? {
        var fields: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        guard let home = fields["home"], !home.isEmpty else { return nil }
        return VenvRecord(home: home, version: fields["version"] ?? fields["version_info"])
    }
}

/// What to do with an existing virtual environment before using it.
enum VenvDisposition: Equatable, Sendable {
    /// No venv yet — create one.
    case absent
    /// Built from the interpreter we're about to use.
    case usable
    /// Present but unusable; delete and rebuild, telling the user why.
    case rebuild(reason: String)
}

enum VenvHealth {

    /// Read the `pyvenv.cfg` beside a venv, if there is one.
    static func record(atVenv venvDir: URL) -> VenvRecord? {
        let config = venvDir.appendingPathComponent("pyvenv.cfg")
        guard let contents = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        return VenvRecord.parse(contents)
    }

    /// Decide what to do with a venv.
    ///
    /// Pure, so every branch is testable without building a real environment.
    ///
    /// - Parameters:
    ///   - record: what the venv says it was built from, or nil if there is none.
    ///   - currentInterpreterBin: the `bin` directory of the interpreter we
    ///     intend to use, or nil if none has been resolved.
    ///   - recordedHomeExists: whether the venv's recorded interpreter is still
    ///     on disk.
    static func disposition(
        record: VenvRecord?,
        currentInterpreterBin: String?,
        recordedHomeExists: Bool
    ) -> VenvDisposition {
        guard let record else { return .absent }

        // Nothing to compare against — judge the venv on whether its own
        // interpreter survives. This is the path when no bundled runtime is
        // present and the venv was built from a system Python.
        guard let currentInterpreterBin else {
            return recordedHomeExists
                ? .usable
                : .rebuild(reason: "the Python it was built from is no longer at \(record.home)")
        }

        if normalize(record.home) == normalize(currentInterpreterBin) {
            // Same path, but a Sparkle update could have replaced what's there.
            return recordedHomeExists
                ? .usable
                : .rebuild(reason: "the Python at \(record.home) is no longer present")
        }

        return .rebuild(
            reason: "it was built from \(record.home), and PsyNeuView now uses \(currentInterpreterBin)")
    }

    /// Trailing slashes and `.` segments shouldn't read as a different path.
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The `bin` directory of an interpreter given its executable path.
    static func binDirectory(ofInterpreter interpreterPath: String) -> String {
        URL(fileURLWithPath: interpreterPath).deletingLastPathComponent().standardizedFileURL.path
    }

    /// Whether the running app sits in /Applications.
    ///
    /// It matters because a venv records the absolute path of its interpreter.
    /// Run the app from the DMG or `~/Downloads` and every venv built in that
    /// session points somewhere that will vanish — so the user gets a rebuild
    /// later, for reasons that would otherwise look arbitrary.
    static func isRunningFromApplications(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        let path = normalize(bundlePath)
        return path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/")
    }
}
