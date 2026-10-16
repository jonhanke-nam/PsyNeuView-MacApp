import Foundation

enum Shell {
    /// Cached toolchain PATH.
    /// `nonisolated(unsafe)`: a benign write-once cache, first resolved during
    /// setup; not worth an actor hop for every shell call (#37).
    nonisolated(unsafe) private static var _toolchainPath: String?

    /// System directories present on every macOS install.
    static let systemBinDirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Homebrew's prefixes: Apple silicon first, then Intel.
    /// Still listed because the installer depends on Homebrew today; #67 drops
    /// these once Python and Node ship inside the bundle (#64 / #65).
    static let homebrewBinDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Compose the PATH the app resolves tools from, most specific first.
    ///
    /// Pure and parameterised so the ordering is testable without touching disk
    /// or spawning a shell.
    static func composePath(
        bundled: [String],
        homebrew: [String] = homebrewBinDirs,
        system: [String] = systemBinDirs
    ) -> String {
        var seen = Set<String>()
        return (bundled + homebrew + system)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// Tool directories shipped inside the app bundle, e.g.
    /// `Contents/Resources/python-3.14.2/bin`. Empty until #64 / #65 land; this
    /// is the seam they plug into.
    static func bundledToolDirectories() -> [String] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { entry in
                let name = entry.lastPathComponent
                return name.hasPrefix("python-") || name.hasPrefix("node-")
            }
            .map { $0.appendingPathComponent("bin").path }
            .filter { fm.fileExists(atPath: $0) }
            .sorted()
    }

    /// The interpreter shipped inside the app bundle, if this build has one.
    ///
    /// Returned as an absolute path rather than left to PATH resolution: the
    /// bundled runtime must win over anything on the user's machine, and relying
    /// on ordering would make that a coincidence rather than a guarantee. (#64)
    static func bundledPythonPath() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("python-") }
            .map { $0.appendingPathComponent("bin/python3").path }
            .filter { fm.isExecutableFile(atPath: $0) }
            .sorted()
            .last
    }

    /// The `uv` shipped inside the app, if this build has one.
    ///
    /// Used to install the backend's dependencies. Measured cold on the same
    /// machine, interpreter and backend: pip 1032s, uv 217s — the difference is
    /// parallel resolution and download across ~100 packages, most of the weight
    /// being PsyNeuLink's tree. (#94)
    static func bundledUvPath() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("uv-") }
            .map { $0.appendingPathComponent("uv").path }
            .filter { fm.isExecutableFile(atPath: $0) }
            .sorted()
            .last
    }

    /// The PATH used for every process the app spawns.
    ///
    /// Deliberately **not** read from the user's shell. GUI apps don't inherit a
    /// shell PATH, and this previously filled that gap by running
    /// `zsh -l -c 'echo $PATH'`. That adopted whatever toolchain the user happened
    /// to have — a conda or pyenv interpreter ahead of Homebrew's would silently
    /// become the one we built the backend venv from. It was inconsistent about it
    /// too: `-l -c` is a login but non-interactive shell, so it sources
    /// `.zprofile` but not `.zshrc`, where conda and pyenv usually write their
    /// initialisation. (#60, under #26.)
    static func toolchainPath() -> String {
        if let cached = _toolchainPath { return cached }
        let path = composePath(bundled: bundledToolDirectories())
        _toolchainPath = path
        return path
    }

    /// Prepend a directory to the cached toolchain PATH (used after installing
    /// Homebrew into a prefix that wasn't present at first resolution).
    static func addToPath(_ dir: String) {
        let current = _toolchainPath ?? toolchainPath()
        if !current.split(separator: ":").contains(Substring(dir)) {
            _toolchainPath = dir + ":" + current
        }
    }

    /// Build an environment dictionary with the app's toolchain PATH
    static func userEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolchainPath()
        return env
    }

    /// Run a short-lived command and return its output.
    /// Reads stdout/stderr concurrently to avoid pipe buffer deadlocks.
    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }
        process.environment = environment ?? userEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Detach stdin so commands like git can't prompt in the terminal
        process.standardInput = FileHandle.nullDevice

        // Heard through the termination handler, attached before launch, as in
        // `runAndWait` (#185). This used to end with `waitUntilExit()`, which
        // waits on the run loop of the thread that launched the process; after
        // the awaits below this code resumes on another thread, so a finished
        // command could go unnoticed forever. On CI it stalled a plain
        // `git rev-parse` whose git had long exited (#13).
        let exit = ExitStatus()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        try process.run()

        // Read pipes concurrently on background threads to prevent deadlock.
        // If we read inside terminationHandler, the pipe buffer can fill up,
        // blocking the process from exiting, which means terminationHandler
        // never fires — classic deadlock.
        async let stdoutData = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let stderrData = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        let outData = await stdoutData
        let errData = await stderrData
        let status = await exit.value()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (status, stdout, stderr)
    }

    /// A process's exit status, set once by its termination handler and
    /// awaited by whoever started it, in either order.
    final class ExitStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiter: CheckedContinuation<Int32, Never>?

        func finish(_ value: Int32) {
            lock.lock()
            status = value
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: value)
        }

        func value() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let status {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    /// Run a command with streaming output, returning exit code when done.
    /// Use this for long-running commands (pip install, npm install) where
    /// the user needs to see progress in real-time.
    @discardableResult
    static func runStreaming(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }
        process.environment = environment ?? userEnvironment()
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            onOutput(str)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            onOutput(str)
        }

        return await runAndWait(
            process, pipes: [stdoutPipe, stderrPipe], onOutput: onOutput)
    }

    /// Like runStreaming but allows writing initial data to stdin.
    /// Used for commands that need a keypress (like gh auth login needing Enter).
    @discardableResult
    static func runStreamingWithStdin(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }
        process.environment = environment ?? userEnvironment()

        // Set up stdin pipe so we can write to it
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            onOutput(str)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            onOutput(str)
        }

        return await runAndWait(
            process, pipes: [stdoutPipe, stderrPipe], onOutput: onOutput,
            afterLaunch: {
                // Write initial data to stdin after a short delay (let the process start)
                if let data = stdinData {
                    Task.detached {
                        try? await Task.sleep(for: .seconds(1))
                        stdinPipe.fileHandleForWriting.write(data)
                        // Don't close — the process may need stdin open for the device flow
                    }
                }
            })
    }

    /// Start `process` and wait for it to exit (#185).
    ///
    /// The termination handler is attached *before* the process starts. It used
    /// to be attached afterwards, inside the continuation, so a command that
    /// finished in between, such as a small fast-forward `git pull`, exited
    /// with no handler to hear it. The continuation was never resumed, and the
    /// launch waited forever on "Starting the PsyNeuView server…".
    static func runAndWait(
        _ process: Process,
        pipes: [Pipe],
        onOutput: @escaping @Sendable (String) -> Void,
        afterLaunch: () -> Void = {}
    ) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // Never started, so the handler will never fire: resume here.
                process.terminationHandler = nil
                for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
                onOutput("Failed to launch: \(error.localizedDescription)\n")
                continuation.resume(returning: -1)
                return
            }
            afterLaunch()
        }
    }

    /// Launch a long-lived process with streaming output handlers
    static func launch(
        executablePath: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }
        process.environment = environment ?? userEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                onStdout(str)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                onStderr(str)
            }
        }

        process.terminationHandler = { proc in
            // Clean up handlers
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            onTermination(proc.terminationStatus)
        }

        try process.run()
        return process
    }

    /// Find the path of a command using the user's PATH
    static func which(_ command: String) async -> String? {
        let result = try? await run("/usr/bin/which", arguments: [command])
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kill a process and its children
    static func killProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Kill the process group
        kill(-pid, SIGTERM)
        // Also kill the process directly as fallback
        process.terminate()
    }

    /// Kill any process listening on a specific port
    static func killPort(_ port: Int) async {
        _ = try? await run("/bin/sh", arguments: [
            "-c", "lsof -tiTCP:\(port) -sTCP:LISTEN | xargs kill 2>/dev/null"
        ])
    }
}
