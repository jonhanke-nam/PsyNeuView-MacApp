import Foundation

/// The steps of installing and starting PsyNeuView, as the user sees them
/// (#196).
///
/// The starting window used to show a spinner and "Still starting", with no
/// idea how far along it was or how long was left. A first install plus first
/// start takes several minutes, and from outside it looked the same as a hang
/// — a real hang (#185) looked exactly like it. Each step here has a plain
/// title and a typical duration, so progress can be shown as a checklist with
/// a time-remaining range.
enum ProgressStep: String, CaseIterable, Codable, Sendable {
    case developerTools
    case githubSignIn
    case python
    case node
    case clonePsyNeuLink
    case getPsyNeuView
    case createEnvironment
    case installPackages
    /// Bytecode and the font cache, so the first start is fast (#223).
    case prepareFastStart
    case installNodePackages
    case buildFrontend
    // A checkout start (#232): what a `git pull` may make necessary.
    case pullCheckout
    case checkNodePackages
    case rebuildFrontend
    case updatePythonPackages
    // Every start (#232): the server, as it reports its own phases.
    case startServer
    /// Shown only when the backend begins one (#232): it can take minutes.
    case installPsyNeuLinkUpdate
    case loadPsyNeuLink
    case warmModelRunner

    var title: String {
        switch self {
        case .developerTools: return "Check developer tools"
        case .githubSignIn: return "Sign in to GitHub"
        case .python: return "Set up Python"
        case .node: return "Set up Node.js"
        case .clonePsyNeuLink: return "Clone PsyNeuLink"
        case .getPsyNeuView: return "Install PsyNeuView"
        case .createEnvironment: return "Create the Python environment"
        case .installPackages: return "Install PsyNeuLink and Python packages"
        case .prepareFastStart: return "Preparing Python for a fast first start"
        case .installNodePackages: return "Install Node.js packages"
        case .buildFrontend: return "Build the frontend"
        case .pullCheckout: return "Updating your checkout"
        case .checkNodePackages: return "Checking interface packages"
        case .rebuildFrontend: return "Rebuilding the interface"
        case .updatePythonPackages: return "Updating Python packages"
        case .startServer: return "Starting the server"
        case .installPsyNeuLinkUpdate: return "Installing the PsyNeuLink update"
        case .loadPsyNeuLink: return "Loading PsyNeuLink"
        case .warmModelRunner: return "Warming up the model runner"
        }
    }

    /// How long a step usually takes, in seconds, before this Mac has any
    /// timings of its own. From measurements where there are some: the
    /// dependency install took 217 s cold with uv (#94), a cold start
    /// 38.67 s (#101), and the first import of PsyNeuLink 6–23 s depending
    /// on endpoint security (#215). Wide on purpose: a range that's honest
    /// beats a countdown that's wrong.
    var typical: ClosedRange<Double> {
        switch self {
        case .developerTools: return 2...300
        case .githubSignIn: return 10...120
        case .python: return 2...60
        case .node: return 5...180
        case .clonePsyNeuLink: return 15...120
        case .getPsyNeuView: return 3...30
        case .createEnvironment: return 3...20
        case .installPackages: return 120...480
        case .prepareFastStart: return 3...30
        case .installNodePackages: return 30...180
        case .buildFrontend: return 20...120
        case .pullCheckout: return 1...20
        case .checkNodePackages: return 5...120
        case .rebuildFrontend: return 8...90
        case .updatePythonPackages: return 2...300
        case .startServer: return 2...30
        case .installPsyNeuLinkUpdate: return 60...400
        case .loadPsyNeuLink: return 2...40
        case .warmModelRunner: return 1...15
        }
    }

    /// The steps of a server start, in the order the backend reports them
    /// (#232). "Starting the server" alone covers everything until /health
    /// on a backend that doesn't report phases.
    static let serverStart: [ProgressStep] = [.startServer, .loadPsyNeuLink, .warmModelRunner]

    /// Every step of a server start, the optional one included, for telling
    /// "how long has the server been starting" (#228).
    static let allServerSteps: Set<ProgressStep> =
        [.startServer, .installPsyNeuLinkUpdate, .loadPsyNeuLink, .warmModelRunner]

    /// Steps that write new Python packages — the ones after which the next
    /// server start is slow on a Mac whose security software inspects each
    /// freshly written native extension as it is first loaded (#228). A
    /// rebuilt interface or a pulled source file doesn't count: the server
    /// doesn't map those.
    static let writesNewFiles: Set<ProgressStep> = [
        .getPsyNeuView, .createEnvironment, .installPackages,
        .updatePythonPackages, .installPsyNeuLinkUpdate,
    ]

    /// The matching step of the installer's own list (`Installer.stepStatuses`).
    init(_ step: InstallStep) {
        switch step {
        case .xcodeTools: self = .developerTools
        case .githubAuth: self = .githubSignIn
        case .python: self = .python
        case .node: self = .node
        case .cloneRepo: self = .getPsyNeuView
        case .createVenv: self = .createEnvironment
        case .installPythonDeps: self = .installPackages
        case .prepareFastStart: self = .prepareFastStart
        case .installNodeDeps: self = .installNodePackages
        case .buildFrontend: self = .buildFrontend
        }
    }
}

/// Which steps each way of installing or starting goes through (#196).
///
/// Only the steps a path actually runs are listed: the wizard used to show
/// all nine installer steps whatever the path, so a bundled install showed
/// Node.js and a frontend build it never does.
enum ProgressPlan {
    enum Path: Equatable {
        /// The Setup Wizard, installing the PsyNeuView included with the app.
        case bundledSetup
        /// The Setup Wizard, cloning or adopting a PsyNeuView checkout.
        case checkoutSetup
        /// Moving to the included PsyNeuView: after an app update (#186), or
        /// switching to it in Settings (#195).
        case update
        /// Rebuilding a missing Python environment (#106).
        case repair
        /// An ordinary launch of the included PsyNeuView.
        case start
        /// A launch of a git checkout (#232): it may pull, and what the pull
        /// brought in decides whether the interface or the packages need
        /// refreshing before the server starts.
        case checkoutStart
    }

    static func steps(
        for path: Path, clonesPsyNeuLink: Bool = false, thenStart: Bool = false
    ) -> [ProgressStep] {
        var steps: [ProgressStep]
        switch path {
        // Every path that writes packages prepares the first start after
        // them (#223); a checkout start adds that step only when its
        // package step installed something, like the PsyNeuLink update.
        case .bundledSetup:
            steps = [.python, .getPsyNeuView, .createEnvironment, .installPackages, .prepareFastStart]
        case .checkoutSetup:
            steps = [.developerTools, .githubSignIn, .python, .node, .getPsyNeuView,
                     .createEnvironment, .installPackages, .prepareFastStart,
                     .installNodePackages, .buildFrontend]
        case .update:
            steps = [.getPsyNeuView, .python, .createEnvironment, .installPackages, .prepareFastStart]
                + ProgressStep.serverStart
        case .repair:
            steps = [.python, .createEnvironment, .installPackages, .prepareFastStart]
                + ProgressStep.serverStart
        case .start:
            steps = ProgressStep.serverStart
        case .checkoutStart:
            steps = [.pullCheckout, .checkNodePackages, .rebuildFrontend, .updatePythonPackages]
                + ProgressStep.serverStart
        }
        // The wizard clones PsyNeuLink first, before the installer runs (#190).
        if clonesPsyNeuLink { steps.insert(.clonePsyNeuLink, at: 0) }
        if thenStart && !steps.contains(.startServer) { steps += ProgressStep.serverStart }
        return steps
    }
}

/// How long is left, as a range, from typical times and this Mac's own (#196).
///
/// Pure: steps and their times in, a range out. The view and the tracker
/// supply the clock.
enum ProgressEstimate {

    /// A step and where it stands, at one moment.
    struct StepState: Equatable {
        enum Status: Equatable {
            case pending
            /// In progress for this many seconds.
            case running(elapsed: Double)
            /// Finished, after this long.
            case done(seconds: Double)
            /// Not needed on this path, with the reason when there is one
            /// ("already up to date"); shown, not hidden (#232).
            case skipped(reason: String?)
            case failed
        }
        var step: ProgressStep
        var status: Status
    }

    struct Estimate: Equatable {
        /// Seconds left, low to high.
        var remaining: ClosedRange<Double>
        /// The step in progress has run past the high end of its usual time.
        var overrunning: Bool
        /// It has run past several times its usual time: worth saying what to
        /// do if it never finishes.
        var stalled: Bool
        /// How far the step in progress is through its usual time, for its
        /// bar; nil when nothing is running.
        var currentFraction: Double?
    }

    /// How many past runs of a step to remember and use.
    static let historyLimit = 5

    /// How long a step is expected to take: this Mac's recent times when
    /// there are some, the typical range otherwise.
    ///
    /// A Mac's own history is a much better guess than a typical figure — the
    /// same step can take 30 s on one machine and 5 min on another — but one
    /// run is not a promise, so it still gives a range around the median.
    static func expected(_ step: ProgressStep, history: [Double]) -> ClosedRange<Double> {
        guard let median = typicalSeconds(history: history) else { return step.typical }
        let low = median * 0.75
        let high = max(median * 1.5, low + 5)
        return low...high
    }

    /// What a step usually takes on this Mac: the median of its last few
    /// recorded runs, so one slow launch (a cold cache, a backup running)
    /// doesn't become the promise. Nil with no history: a typical figure
    /// from another machine is not "usually" on this one (#232).
    static func typicalSeconds(history: [Double]) -> Double? {
        let recent = history.suffix(historyLimit).filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !recent.isEmpty else { return nil }
        return recent.count % 2 == 1
            ? recent[recent.count / 2]
            : (recent[recent.count / 2 - 1] + recent[recent.count / 2]) / 2
    }

    /// "usually about 25 s", "usually about 2 min", "usually under a second".
    static func usualPhrase(seconds: Double) -> String {
        if seconds < 1 { return "usually under a second" }
        if seconds < 90 { return "usually about \(Int(seconds.rounded())) s" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "usually about 1 min" : "usually about \(minutes) min"
    }

    static func estimate(
        _ steps: [StepState], history: [ProgressStep: [Double]] = [:]
    ) -> Estimate {
        var low = 0.0, high = 0.0
        var overrunning = false, stalled = false
        var fraction: Double?
        for state in steps {
            let range = expected(state.step, history: history[state.step] ?? [])
            switch state.status {
            case .pending:
                low += range.lowerBound
                high += range.upperBound
            case .running(let elapsed):
                low += max(0, range.lowerBound - elapsed)
                high += max(0, range.upperBound - elapsed)
                if elapsed > range.upperBound { overrunning = true }
                if elapsed > range.upperBound * 3 { stalled = true }
                let middle = (range.lowerBound + range.upperBound) / 2
                fraction = middle > 0 ? min(elapsed / middle, 0.95) : 0.95
            case .done, .skipped, .failed:
                break
            }
        }
        return Estimate(
            remaining: low...high, overrunning: overrunning, stalled: stalled,
            currentFraction: fraction)
    }

    // MARK: The slow first start (#228)

    /// After this many seconds of server start, following an install that
    /// wrote new packages, say why it is slow.
    static let slowStartAfter: Double = 15

    static let slowStartExplanation =
        "The first start after an update is slower on Macs with security software, "
        + "which checks the newly installed files. Later starts take a few seconds."

    /// The plain line to show while a server start runs long, or nil.
    ///
    /// Shown only when both hold: this launch wrote new Python packages (a
    /// step in `ProgressStep.writesNewFiles` ran, not skipped), and the
    /// server steps have been going for `slowStartAfter` seconds or more
    /// with one still in progress. A long start with no new files isn't
    /// explained by security software, and saying so would mislead; a
    /// finished start needs no explaining.
    static func slowStartNotice(_ steps: [StepState], after threshold: Double = slowStartAfter) -> String? {
        var wroteNewFiles = false
        var serverSeconds = 0.0
        var serverRunning = false
        for state in steps {
            switch state.status {
            case .done(let seconds):
                if ProgressStep.writesNewFiles.contains(state.step) { wroteNewFiles = true }
                if ProgressStep.allServerSteps.contains(state.step) { serverSeconds += seconds }
            case .running(let elapsed):
                if ProgressStep.allServerSteps.contains(state.step) {
                    serverSeconds += elapsed
                    serverRunning = true
                }
            case .pending, .skipped, .failed:
                break
            }
        }
        guard wroteNewFiles, serverRunning, serverSeconds >= threshold else { return nil }
        return slowStartExplanation
    }

    /// "About 3–8 minutes left", never a countdown to the second.
    static func phrase(_ estimate: Estimate) -> String {
        let low = estimate.remaining.lowerBound
        let high = estimate.remaining.upperBound
        if estimate.overrunning && high < 30 {
            return "Taking longer than usual"
        }
        if high < 60 { return "Less than a minute left" }
        let lowMinutes = max(1, Int((low / 60).rounded()))
        let highMinutes = max(lowMinutes, Int((high / 60).rounded(.up)))
        if lowMinutes == highMinutes {
            return lowMinutes == 1 ? "About a minute left" : "About \(lowMinutes) minutes left"
        }
        return "About \(lowMinutes)–\(highMinutes) minutes left"
    }

    /// `0:42`, `12:03`, `1:02:03`.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// This Mac's recorded step times, kept between runs (#196).
///
/// Under its own key, `progressStepTimings`: step name -> the last few
/// durations in seconds. Nothing else in the app's settings is touched.
struct StepTimings {
    static let key = "progressStepTimings"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func history() -> [ProgressStep: [Double]] {
        guard let stored = defaults.dictionary(forKey: Self.key) as? [String: [Double]] else {
            return [:]
        }
        var result: [ProgressStep: [Double]] = [:]
        for (name, times) in stored {
            if let step = ProgressStep(rawValue: name) { result[step] = times }
        }
        return result
    }

    func record(_ step: ProgressStep, seconds: Double) {
        var stored = defaults.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
        stored[step.rawValue] = Self.appending(seconds, to: stored[step.rawValue] ?? [])
        defaults.set(stored, forKey: Self.key)
    }

    /// Keep the most recent few, oldest first.
    static func appending(_ seconds: Double, to list: [Double]) -> [Double] {
        guard seconds.isFinite, seconds >= 0 else { return list }
        return Array((list + [seconds]).suffix(ProgressEstimate.historyLimit))
    }
}
