import Foundation
import Darwin

/// The command Claude Desktop and Claude Code start to use PsyNeuView's AI
/// assistant over MCP, at a path that survives app updates (#86,
/// PsyNeuView#201).
///
/// PsyNeuView's Settings shows the user a setup to paste into Claude, and that
/// setup names a command by path. Left to itself the backend names the one
/// inside the installed version's folder,
/// `…/Application Support/PsyNeuView/psyneuview-<version>/backend/.venv/…`,
/// which the next update moves, silently breaking what was pasted.
///
/// So on every start the app writes a small launcher at a fixed path,
/// `…/Application Support/PsyNeuView/bin/psyneuview-mcp` (`PsyNeuView-Test`
/// for the test app, which keeps its own), that runs the PsyNeuView in use,
/// and tells the backend about it with `PSYNEUVIEW_MCP_LAUNCHER`; the setup
/// then names the fixed path (PsyNeuView's `docs/ai-assistant/mcp.md`).
///
/// It is a script rather than a link: a regular file the app writes itself,
/// so nothing about it follows a link, and it works whether or not that
/// install has the `psyneuview-mcp` console script.
///
/// Safety: the `bin` folder must be a real folder owned by the user and is
/// kept user-only (0700); the launcher is user-only (0700) and is replaced
/// atomically, written beside the old one and renamed over it, so Claude
/// never starts a half-written file. A PsyNeuView without the MCP command
/// gets no launcher and no variable.
enum McpLauncher {

    /// What the backend reads (PsyNeuView `mcp_link.LAUNCHER_ENV`).
    static let variable = "PSYNEUVIEW_MCP_LAUNCHER"

    static let folderName = "bin"
    static let fileName = "psyneuview-mcp"

    /// The first lines of every launcher, so one can be recognised as ours.
    static let marker = "# PsyNeuView's MCP command for Claude Desktop and Claude Code"

    enum Failure: LocalizedError, Equatable {
        case notAFolder(String)
        case notYours(String)
        case io(String, Int32)

        var errorDescription: String? {
            switch self {
            case .notAFolder(let path):
                return "\(path) is a link or a file, not a folder; refusing to write there."
            case .notYours(let path):
                return "\(path) belongs to another account; refusing to write there."
            case .io(let what, let code):
                return "\(what): \(String(cString: strerror(code)))"
            }
        }
    }

    // MARK: Paths

    /// `<support>/bin`.
    static func folder(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// `<support>/bin/psyneuview-mcp`: the path the setup names.
    static func path(supportDirectory: URL) -> URL {
        folder(supportDirectory: supportDirectory).appendingPathComponent(fileName)
    }

    /// The fixed path for an identity: the test app's is its own.
    static func path(identity: AppIdentity) -> URL {
        path(supportDirectory: identity.supportDirectory())
    }

    // MARK: The script

    /// Whether `repoPath` has what the launcher runs: the backend's Python
    /// and the MCP command (PsyNeuView versions before the assistant don't).
    static func canLaunch(repoPath: URL, fileManager fm: FileManager = .default) -> Bool {
        let backend = repoPath.appendingPathComponent("backend")
        return fm.isExecutableFile(atPath: backend.appendingPathComponent(".venv/bin/python").path)
            && fm.fileExists(atPath: backend.appendingPathComponent("app/mcp_server.py").path)
    }

    /// The launcher's text for the PsyNeuView at `repoPath`. `PYTHONPATH`
    /// names that tree's backend, so it runs that tree's code whatever the
    /// environment's own install is.
    static func script(repoPath: URL) -> String {
        let backend = repoPath.appendingPathComponent("backend")
        let python = backend.appendingPathComponent(".venv/bin/python")
        return """
        #!/bin/sh
        \(marker) (PsyNeuView#201).
        # The PsyNeuView app rewrites this on every start so it always runs the
        # PsyNeuView in use; the setup pasted into Claude names this file, so it
        # survives app updates. Don't edit it: changes are replaced.
        PYTHONPATH=\(shellQuoted(backend.path))
        export PYTHONPATH
        exec \(shellQuoted(python.path)) -m app.mcp_server "$@"

        """
    }

    /// `'…'`, with any `'` written as `'\''`: safe for any path.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Writing it

    /// Writes (or replaces) the launcher for `repoPath` and returns its path,
    /// or, when that tree can't run the MCP command, removes any launcher
    /// left from another tree and returns nil.
    ///
    /// An unchanged launcher is left as it is (same file, no write).
    @discardableResult
    static func install(
        repoPath: URL, supportDirectory: URL, fileManager fm: FileManager = .default
    ) throws -> URL? {
        let target = path(supportDirectory: supportDirectory)
        guard canLaunch(repoPath: repoPath, fileManager: fm) else {
            try remove(supportDirectory: supportDirectory)
            return nil
        }
        let dir = try prepareFolder(supportDirectory: supportDirectory, fileManager: fm)
        let text = script(repoPath: repoPath)

        if isCurrent(target, text: text) { return target }
        try replaceAtomically(target, in: dir, contents: Data(text.utf8))
        return target
    }

    /// Removes the launcher, if there is one. The `bin` folder stays. Never
    /// follows a link: a link at the launcher's path is removed itself.
    static func remove(supportDirectory: URL) throws {
        let target = path(supportDirectory: supportDirectory)
        if unlink(target.path) != 0, errno != ENOENT, errno != ENOTDIR {
            throw Failure.io("Couldn't remove \(target.path)", errno)
        }
    }

    /// The variables to start the backend with: the launcher's path when
    /// there is one, nothing otherwise.
    static func backendVariables(launcher: URL?) -> [String: String] {
        guard let launcher else { return [:] }
        return [variable: launcher.path]
    }

    // MARK: Internals

    /// Makes `<support>/bin`, or checks the one there: a real folder (not a
    /// link) owned by this user, then made user-only. The support folder
    /// itself must belong to this user too.
    static func prepareFolder(supportDirectory: URL, fileManager fm: FileManager = .default) throws -> URL {
        let uid = getuid()
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        var st = stat()
        guard stat(supportDirectory.path, &st) == 0 else {
            throw Failure.io("Couldn't read \(supportDirectory.path)", errno)
        }
        guard st.st_uid == uid else { throw Failure.notYours(supportDirectory.path) }

        let dir = folder(supportDirectory: supportDirectory)
        if mkdir(dir.path, 0o700) != 0, errno != EEXIST {
            throw Failure.io("Couldn't make \(dir.path)", errno)
        }
        guard lstat(dir.path, &st) == 0 else { throw Failure.io("Couldn't read \(dir.path)", errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.notAFolder(dir.path) }
        guard st.st_uid == uid else { throw Failure.notYours(dir.path) }
        if (st.st_mode & 0o777) != 0o700, chmod(dir.path, 0o700) != 0 {
            throw Failure.io("Couldn't make \(dir.path) yours only", errno)
        }
        return dir
    }

    /// Whether `target` is already this launcher: a regular file of ours,
    /// user-only, with exactly this text.
    static func isCurrent(_ target: URL, text: String) -> Bool {
        var st = stat()
        guard lstat(target.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o700,
              let data = FileManager.default.contents(atPath: target.path)
        else { return false }
        return data == Data(text.utf8)
    }

    /// Writes `contents` to a new user-only file beside `target`, never
    /// through a link, then renames it over `target`: whoever opens `target`
    /// sees the old launcher or the new one, never half of one.
    static func replaceAtomically(_ target: URL, in dir: URL, contents: Data) throws {
        let temp = dir.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard fd >= 0 else { throw Failure.io("Couldn't write \(temp.path)", errno) }
        var ok = false
        defer {
            if !ok { unlink(temp.path) }
        }
        do {
            defer { close(fd) }
            let written = contents.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                var done = 0
                while done < buf.count {
                    let n = write(fd, base + done, buf.count - done)
                    if n <= 0 { return -1 }
                    done += n
                }
                return done
            }
            guard written == contents.count else { throw Failure.io("Couldn't write \(temp.path)", errno) }
            // The umask can't widen it, but make the mode exact whatever it is.
            guard fchmod(fd, 0o700) == 0 else { throw Failure.io("Couldn't set \(temp.path)'s mode", errno) }
            guard fsync(fd) == 0 else { throw Failure.io("Couldn't save \(temp.path)", errno) }
        }
        guard rename(temp.path, target.path) == 0 else {
            throw Failure.io("Couldn't put the launcher at \(target.path)", errno)
        }
        ok = true
    }
}
