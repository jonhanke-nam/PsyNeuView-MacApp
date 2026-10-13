import Foundation

enum Constants {
    static let healthPollInterval: TimeInterval = 1.0

    /// How long to wait before telling the user the backend is taking a while.
    ///
    /// Not a failure — just the point at which silence stops being reassuring.
    static let healthSlowAfter: TimeInterval = 20.0

    /// How long to wait before giving up entirely.
    ///
    /// Was 30 seconds, which is less than the work takes: a 0.5.3 install
    /// reported PsyNeuLink warming up in 38.67s, so the app declared failure 11
    /// seconds before its own backend became healthy. Importing PsyNeuLink is
    /// genuinely slow, and the first run — cold filesystem cache, freshly
    /// installed packages — is the slowest case and the one everybody hits.
    ///
    /// Generous on purpose. A slow machine is not a failure, and the process
    /// dying is detected separately and immediately. (#101)
    static let healthTimeout: TimeInterval = 600.0
    static let maxLogLines: Int = 10_000

    // PsyNeuView is public since 2026-10-13 (fresh history; the older private
    // history is jonhanke-nam/PsyNeuView-archive), so HTTPS needs no key.
    static let psyneuviewRepoURL = "https://github.com/jonhanke-nam/PsyNeuView.git"

    /// Build health URL for a given port
    static func backendHealthURL(port: Int) -> String {
        "http://localhost:\(port)/health"
    }

    /// Build frontend URL for a given port
    static func frontendURL(port: Int) -> String {
        "http://localhost:\(port)"
    }
}
