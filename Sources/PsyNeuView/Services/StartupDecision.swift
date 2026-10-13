import Foundation

/// What should be on screen while the app is starting, as a function (#104).
///
/// Three bugs reached users from real installs, and none was a logic fault —
/// all three were sequencing: a finished install showing the debug log instead
/// of the app (#96), startup declared failed eleven seconds before the backend
/// came up (#101), a retry button offered when retrying could not help (#101).
///
/// They shared a cause. "Given setup state, backend status and elapsed time,
/// what should be on screen?" was spread across `AppDelegate`, `ProcessManager`
/// and `HealthChecker`, decided by callbacks firing in an order no test
/// exercised. A suite of 109 tests covered the pure functions thoroughly and
/// could not see any of it.
///
/// As one function it has a truth table, and the cases that shipped broken can
/// each be asserted.
enum StartupDecision {

    /// Everything the decision depends on. No clock, no network, no windows —
    /// the caller reads those and passes them in.
    struct Input {
        /// Setup has been completed at least once, so there is an install to run.
        var setupCompleted: Bool
        /// The backend answered its health endpoint.
        var backendHealthy: Bool
        /// The backend process is alive. False once it has exited.
        var backendRunning: Bool
        /// Seconds since the launch attempt began.
        var elapsed: TimeInterval
        /// When to stop waiting, from Constants.
        var ceiling: TimeInterval
        /// When to start reassuring, from Constants.
        var reassureAfter: TimeInterval
    }

    /// What the user should be looking at.
    enum Screen: Equatable {
        /// First run, or setup never finished.
        case setupWizard
        /// Starting, with something to say about it.
        case starting(message: String)
        /// The app itself.
        case app
        /// It did not start, with why and whether trying again could help.
        case failed(reason: String, retryable: Bool)
    }

    /// Reassurance shown once a start is slow enough to feel like a hang.
    ///
    /// Not a failure and not silence. #101 was a user watching a progress
    /// spinner with no indication anything was still happening, followed by a
    /// declaration of failure while PsyNeuLink was still importing.
    static let slowMessage =
        "Still starting — PsyNeuLink takes a while to load the first time."

    static let startingMessage = "Starting the PsyNeuView server…"

    /// Decide what belongs on screen.
    ///
    /// Order matters, and each rule is here because of a specific failure:
    ///
    /// 1. No setup → the wizard. Nothing else can be true yet.
    /// 2. Healthy → the app, immediately, whatever else is going on. A
    ///    finished start must never leave the log or the spinner up (#96).
    /// 3. Process gone → failed, without waiting out the ceiling. Waiting is
    ///    only useful while something might still answer.
    /// 4. Past the ceiling → failed, but *retryable*: the install is fine, it
    ///    was just slower than we allowed.
    /// 5. Otherwise → starting, reassuring once it is slow enough to worry.
    static func screen(for input: Input) -> Screen {
        guard input.setupCompleted else { return .setupWizard }

        if input.backendHealthy { return .app }

        if !input.backendRunning {
            // Retrying cannot help: the process is not coming back on its own,
            // and offering the button again is what made #101 log "Cannot
            // start" four times.
            return .failed(
                reason: "The PsyNeuView server stopped before it finished starting.",
                retryable: false)
        }

        if input.elapsed > input.ceiling {
            return .failed(
                reason: "PsyNeuView did not finish starting within "
                    + "\(Int(input.ceiling / 60)) minutes.",
                retryable: true)
        }

        return .starting(
            message: input.elapsed > input.reassureAfter ? slowMessage : startingMessage)
    }
}
