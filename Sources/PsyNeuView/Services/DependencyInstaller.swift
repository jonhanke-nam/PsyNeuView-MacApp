import AppKit
import Foundation

/// Prepares the machine for PsyNeuView.
///
/// Deliberately installs as little as possible. Python and PsyNeuView ship inside
/// the app (#64, #74), so a default install needs nothing from the outside world
/// and this type mostly *checks* rather than installs.
///
/// Homebrew is never installed. Mutating a shared package prefix on someone's
/// machine is exactly what this work exists to stop doing — so where a developer
/// build genuinely needs a tool we don't ship, we say what to install rather than
/// installing it for them. (#67, under #26)
@MainActor
final class DependencyInstaller {
    var onOutput: ((String) -> Void)?

    /// Absolute path to the interpreter `installPython()` settled on.
    ///
    /// Venv creation uses this directly rather than looking up `python3` on PATH,
    /// which is what previously forced us to mutate the Homebrew prefix. (#62)
    private(set) var resolvedPythonPath: String?

    private func log(_ message: String) {
        onOutput?(message)
    }

    // MARK: - Check what's already installed

    func isGitInstalled() async -> Bool {
        await Shell.which("git") != nil
    }

    /// Whether the app already holds a usable GitHub grant — refreshing it if
    /// the eight-hour token has lapsed. (#63)
    func isGitHubAuthenticated() async -> Bool {
        await GitHubCredential.validAccessToken() != nil
    }

    func isPythonInstalled() async -> Bool {
        await findUsablePython() != nil
    }

    /// Returns the absolute path to an interpreter inside PsyNeuView's supported
    /// range (`PythonRequirement`), either via PATH, via a versioned interpreter
    /// already on this Mac, or via an installed Homebrew `python@X.Y` keg.
    /// When found inside a keg that isn't linked into PATH, we still report it as
    /// installed — `installPython` links it before the next step.
    func findUsablePython() async -> String? {
        // A bundled runtime wins outright — it is the whole point of #64, and it
        // is the only interpreter whose version we control.
        if let bundled = Shell.bundledPythonPath(),
           await pythonVersionMeetsMinimum(at: bundled) {
            return bundled
        }
        if let path = await Shell.which("python3"),
           await pythonVersionMeetsMinimum(at: path) {
            return path
        }
        // `python3` is absent or out of range. Look for a versioned interpreter
        // the user already has — the same courtesy PsyNeuView's Makefile extends.
        // We do not install one: that would mean touching their toolchain. (#61, #67)
        if let alternative = await supportedInterpreterOnPath() {
            return alternative
        }
        return nil
    }

    /// The newest supported versioned interpreter reachable on PATH
    /// (`python3.14`, `python3.13`, `python3.12`), or nil if none is.
    func supportedInterpreterOnPath() async -> String? {
        for name in PythonRequirement.supportedInterpreters {
            if let path = await Shell.which(name),
               await pythonVersionMeetsMinimum(at: path) {
                return path
            }
        }
        return nil
    }

    /// The version string an interpreter reports, e.g. "3.11.9".
    func pythonVersion(at path: String) async -> String? {
        let result = try? await Shell.run(path, arguments: ["--version"])
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout
            .replacingOccurrences(of: "Python ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pythonVersionMeetsMinimum(at path: String) async -> Bool {
        let result = try? await Shell.run(path, arguments: ["--version"])
        guard let result, result.exitCode == 0 else { return false }
        let version = result.stdout.replacingOccurrences(of: "Python ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PythonRequirement.isSupported(version)
    }

    func isNodeInstalled() async -> Bool {
        guard let path = await Shell.which("node") else { return false }
        let result = try? await Shell.run(path, arguments: ["--version"])
        guard let result, result.exitCode == 0 else { return false }
        var version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") { version = String(version.dropFirst()) }
        return isVersionAtLeast(version, minimum: "18.0")
    }

    // MARK: - Install prerequisites

    /// Install Xcode Command Line Tools (required for git).
    /// This shows a system dialog that the user must click through.
    func installXcodeCliTools() async -> Bool {
        log("Checking for Xcode Command Line Tools...")

        if await isGitInstalled() {
            log("  ✓ Already installed")
            return true
        }

        log("  Installing Xcode Command Line Tools...")
        log("  A system dialog will appear — click 'Install' to proceed.")

        // Trigger the install dialog
        _ = try? await Shell.run("/usr/bin/xcode-select", arguments: ["--install"])

        // Poll until git becomes available (user is clicking through the dialog)
        log("  Waiting for installation to complete...")
        for _ in 0..<120 { // Wait up to 10 minutes
            try? await Task.sleep(for: .seconds(5))
            if await isGitInstalled() {
                log("  ✓ Xcode Command Line Tools installed")
                return true
            }
        }

        log("  ✗ Timed out waiting for Xcode Command Line Tools")
        return false
    }

    /// Authorise with GitHub using the OAuth device flow.
    ///
    /// Runs the flow natively rather than installing the `gh` CLI to do it: the
    /// app shows the one-time code, opens the browser, polls for the grant, and
    /// keeps it in its own Keychain entry. The issued token is restricted to the
    /// PsyNeuView repository alone. (#63, under #26)
    func authenticateGitHub() async -> Bool {
        log("Checking GitHub authorisation...")

        if await isGitHubAuthenticated() {
            log("  ✓ Already authorised")
            return true
        }

        let device: GitHubDeviceFlow.DeviceCode
        do {
            device = try await GitHubDeviceFlow.start()
        } catch {
            log("  ✗ \(error.localizedDescription)")
            return false
        }

        // Put the code where the user can't miss it, then open the browser.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(device.userCode, forType: .string)
        log("")
        log("  Your one-time code: \(device.userCode)")
        log("  (copied to the clipboard)")
        log("  Enter it at \(device.verificationURI.absoluteString), then come back here.")
        log("")
        NSWorkspace.shared.open(device.verificationURI)

        let deadline = Date().addingTimeInterval(device.expiresIn)
        var interval = device.interval

        while Date() < deadline {
            try? await Task.sleep(for: .seconds(interval))
            let outcome: GitHubDeviceFlow.PollOutcome
            do {
                outcome = try await GitHubDeviceFlow.poll(
                    deviceCode: device.deviceCode,
                    currentInterval: interval
                )
            } catch {
                // A transient network blip shouldn't end the flow — the user may
                // still be mid-authorisation. Keep polling until the code expires.
                continue
            }

            switch outcome {
            case .authorized(let grant):
                guard GitHubCredential.save(grant) else {
                    log("  ✗ Couldn't save the GitHub credential to the Keychain.")
                    return false
                }
                log("  ✓ Authorised with GitHub")
                return true
            case .pending:
                continue
            case .slowDown(let newInterval):
                interval = newInterval
            case .failed(let reason):
                log("  ✗ \(reason)")
                return false
            }
        }

        log("  ✗ \(GitHubDeviceFlow.FlowError.timedOut.localizedDescription)")
        return false
    }

    /// Resolve an interpreter inside PsyNeuView's supported range.
    ///
    /// Never installs one. A default install has the bundled runtime (#64); a
    /// developer build without it uses a supported interpreter already on the
    /// machine, and says what to install if there isn't one. Installing Python on
    /// someone's behalf means Homebrew, and Homebrew means mutating a shared
    /// prefix. (#67)
    func installPython() async -> Bool {
        log("Checking for Python \(PythonRequirement.supportedVersionsDescription)...")

        if let bundled = Shell.bundledPythonPath() {
            if await pythonVersionMeetsMinimum(at: bundled) {
                resolvedPythonPath = bundled
                log("  ✓ Using the bundled runtime (\(bundled))")
                return true
            }
            // A bundled interpreter outside the supported range is a packaging
            // error, not something to work around.
            let found = await pythonVersion(at: bundled) ?? "unknown"
            log("  ✗ Bundled Python reports \(found), outside \(PythonRequirement.supportedVersionsDescription).")
            log("    This is a build error — scripts/python-runtime.conf and PythonRequirement disagree.")
            return false
        }

        // No bundled runtime: a developer build. Use what's already here.
        if let existing = await findUsablePython() {
            resolvedPythonPath = existing
            log("  ✓ Using \(existing)")
            return true
        }

        let onPath = await Shell.which("python3")
        if let onPath, let version = await pythonVersion(at: onPath) {
            log("  ✗ Python \(version) at \(onPath) is outside \(PythonRequirement.supportedVersionsDescription).")
        } else {
            log("  ✗ No Python \(PythonRequirement.supportedVersionsDescription) found.")
        }
        log("    This build has no bundled runtime. Install a supported Python —")
        log("    for example `brew install \(PythonRequirement.preferredFormula)` —")
        log("    then run setup again. PsyNeuView won't install it for you, so it")
        log("    can't disturb the toolchain you already have.")
        return false
    }

    /// Check for Node 18+, which only the clone path needs.
    ///
    /// A bundled PsyNeuView ships its frontend already built, so this is never
    /// reached by a default install. When it is reached, we report rather than
    /// install: a developer's Node version is theirs to choose. (#67)
    func installNode() async -> Bool {
        log("Checking for Node.js 18+...")

        if await isNodeInstalled() {
            log("  ✓ Found")
            return true
        }

        log("  ✗ Node.js 18+ is required to build the frontend from a clone.")
        log("    Install it — for example `brew install node`, or from nodejs.org —")
        log("    then run setup again.")
        log("    (A bundled PsyNeuView needs no Node at all; this is only the")
        log("    developer path.)")
        return false
    }

    // MARK: - Clone the repo over HTTPS using our own token

    /// Clone the PsyNeuView repo with the token from `authenticateGitHub()`.
    /// Clones the `devel` branch — the active, CI-tested trunk. `main` is
    /// dormant (no devel->main promotion) and would be months stale.
    ///
    /// The credential is passed as `git -c <config>` *before* the subcommand, so
    /// it applies to this invocation only and is never written into the new
    /// repository's `.git/config` — unlike embedding it in the remote URL. (#63)
    func cloneRepo(into directory: URL) async -> Bool {
        log("Cloning PsyNeuView repository (devel branch)...")

        guard let token = await GitHubCredential.validAccessToken() else {
            log("  ✗ Not authorised with GitHub yet.")
            return false
        }
        guard let gitPath = await Shell.which("git") else {
            log("  ✗ git not found")
            return false
        }

        let exitCode = await Shell.runStreaming(
            gitPath,
            arguments: [
                "-c", GitHubCredential.gitAuthConfig(token: token),
                "clone", "--branch", "devel",
                "https://github.com/jonhanke-nam/PsyNeuView.git",
                directory.path,
            ],
            onOutput: { [weak self] text in
                Task { @MainActor [weak self] in
                    // Never let the header reach the log window.
                    self?.log(GitHubCredential.redact(
                        text.trimmingCharacters(in: .whitespacesAndNewlines),
                        token: token
                    ))
                }
            }
        )

        if exitCode == 0 {
            let makefile = directory.appendingPathComponent("Makefile")
            if FileManager.default.fileExists(atPath: makefile.path) {
                log("  ✓ Repository cloned (devel branch)")
                return true
            }
        }

        // The most common cause by far, and the least obvious from git's output.
        log("  ✗ Clone failed — check that your GitHub account has access to")
        log("    jonhanke-nam/PsyNeuView.")
        return false
    }

    // MARK: - Helpers

    private func isVersionAtLeast(_ version: String, minimum: String) -> Bool {
        SemanticVersion.isAtLeast(version, minimum: minimum)
    }
}
