import Foundation

/// What should be on screen while PsyNeuView starts.
///
/// Three bugs reached users from this path in one day — #89, #96, #101 — and all
/// three were sequencing faults rather than logic faults: which window shows,
/// what happens when starting is slow, whether the offered recovery can act.
/// They were spread across AppDelegate, ProcessManager and HealthChecker,
/// decided by callbacks firing in an order no test exercised.
///
/// Expressing the decision as a pure function makes each of those assertable.
/// (#104)
enum StartupSequence {

    /// Where startup has got to.
    enum Phase: Equatable, Sendable {
        /// Nothing installed yet.
        case notConfigured
        /// Installed, but the tree is no longer where it was put.
        case treeMissing(path: String)
        /// Launching; `elapsed` is how long the backend has been coming up.
        case starting(elapsed: TimeInterval)
        /// Backend answered.
        case ready
        /// Gave up, or the process died.
        case failed(reason: String)
    }

    /// What the app should do about it.
    enum Action: Equatable, Sendable {
        case showSetupWizard
        /// A window with a status message — never the log. Setup used to end on
        /// the log window, which is what #96 was.
        case showStarting(status: String)
        case showAppWindow
        case showFailure(reason: String)
    }

    /// Decide what to show.
    ///
    /// - Parameter slowAfter: when to stop being silent and say it's still
    ///   working. Silence past this point reads as a hang.
    static func action(
        for phase: Phase,
        slowAfter: TimeInterval = Constants.healthSlowAfter
    ) -> Action {
        switch phase {
        case .notConfigured:
            return .showSetupWizard

        case .treeMissing(let path):
            return .showFailure(
                reason: "PsyNeuView isn't where it was installed (\(path)). "
                      + "Run the Setup Wizard to reinstall it.")

        case .starting(let elapsed):
            // A slow start is not a failure. #101 shipped a 30-second ceiling
            // against a 38.67-second warm-up and called the difference an error.
            if elapsed > slowAfter {
                return .showStarting(
                    status: "Still starting — PsyNeuLink has been loading for "
                          + "\(Int(elapsed))s. The first run is the slowest.")
            }
            return .showStarting(status: "Starting the PsyNeuView server…")

        case .ready:
            return .showAppWindow

        case .failed(let reason):
            return .showFailure(reason: reason)
        }
    }

    /// Whether offering "Try Again" can achieve anything.
    ///
    /// #101: the button called `startAll` unconditionally, which refuses while
    /// the server is already starting — so the only recovery on screen logged
    /// "Cannot start: server is not in stopped state" and the user clicked it
    /// four times. A control that cannot act should not be offered as one.
    static func retryIsUseful(canStart: Bool) -> Bool {
        canStart
    }
}
