import Foundation
import Observation

/// Follows one install or start as it happens, for the progress view (#196).
///
/// Holds when each step began and how long finished ones took; the estimate
/// itself is `ProgressEstimate`, which is pure. Finished steps' times are
/// handed to `record`, so the next run's estimate is this Mac's own.
@MainActor
@Observable
final class InstallProgress {
    enum Tracked: Equatable {
        case pending
        case running(since: Date)
        case done(seconds: Double)
        /// Not needed on this path, with the reason when one was given (#232).
        case skipped(reason: String?)
        case failed(String)
    }

    /// A part of a step, timed on its own (#215): a phase of the package
    /// install read from pip's or uv's output, or the moment the server
    /// answered /health. Not shown on the checklist; carried in the boot
    /// report and Report a Problem, where "install took 240 s" needs to say
    /// which 240 s.
    struct Detail: Equatable, Codable, Sendable {
        /// Stable, for comparing runs: "psyneulink/resolveAndDownload".
        var id: String
        var title: String
        var seconds: Double
        /// Bytes downloaded, when known.
        var bytes: Int64?
    }

    /// The steps, in order. A step the backend only sometimes runs — the
    /// PsyNeuLink update — is inserted when it begins (#232).
    private(set) var steps: [ProgressStep]
    let startedAt: Date
    private(set) var statuses: [ProgressStep: Tracked]
    /// Details noted under each step, in the order they were noted.
    private(set) var details: [ProgressStep: [Detail]] = [:]
    /// Whether the backend has reported any phase of its start (#232). Nil
    /// until /health answers or a phase line arrives.
    private(set) var sawServerPhases = false
    @ObservationIgnored private let history: [ProgressStep: [Double]]
    @ObservationIgnored private let record: (ProgressStep, Double) -> Void

    init(
        steps: [ProgressStep],
        startedAt: Date = Date(),
        history: [ProgressStep: [Double]] = [:],
        record: @escaping (ProgressStep, Double) -> Void = { _, _ in }
    ) {
        self.steps = steps
        self.startedAt = startedAt
        self.history = history
        self.record = record
        self.statuses = Dictionary(uniqueKeysWithValues: steps.map { ($0, .pending) })
    }

    /// One backed by this Mac's stored timings.
    static func recorded(_ steps: [ProgressStep]) -> InstallProgress {
        let timings = StepTimings()
        return InstallProgress(
            steps: steps, history: timings.history(),
            record: { step, seconds in timings.record(step, seconds: seconds) })
    }

    func begin(_ step: ProgressStep, at now: Date = Date()) {
        guard statuses[step] != nil else { return }
        // Anything earlier still pending was not needed on this path.
        for earlier in steps.prefix(while: { $0 != step }) where statuses[earlier] == .pending {
            statuses[earlier] = .skipped(reason: nil)
        }
        statuses[step] = .running(since: now)
    }

    func finish(_ step: ProgressStep, at now: Date = Date()) {
        guard let status = statuses[step] else { return }
        switch status {
        case .running(let since):
            let seconds = now.timeIntervalSince(since)
            statuses[step] = .done(seconds: seconds)
            record(step, seconds)
        case .pending:
            statuses[step] = .skipped(reason: nil)
        case .done, .skipped, .failed:
            break
        }
    }

    /// The step was not needed, and this is why — "already up to date". A
    /// step that was running while that was found out (a check that came
    /// back with nothing to do) is skipped too, and its time isn't recorded
    /// as a run (#232).
    func skip(_ step: ProgressStep, reason: String?) {
        guard let status = statuses[step] else { return }
        switch status {
        case .pending, .running:
            statuses[step] = .skipped(reason: reason)
        case .done, .skipped, .failed:
            break
        }
    }

    func fail(_ step: ProgressStep, reason: String) {
        guard statuses[step] != nil else { return }
        statuses[step] = .failed(reason)
    }

    /// Fail whichever step is in progress, if any.
    func failCurrent(reason: String) {
        if let step = currentStep { fail(step, reason: reason) }
    }

    /// Add a step the plan didn't list, right after another (#232): the
    /// backend installs a PsyNeuLink update only sometimes, and the step
    /// appears when it does rather than reading "not needed" every other day.
    func insert(_ step: ProgressStep, after anchor: ProgressStep) {
        guard statuses[step] == nil else { return }
        let index = steps.firstIndex(of: anchor).map { $0 + 1 } ?? steps.count
        steps.insert(step, at: index)
        statuses[step] = .pending
    }

    /// Record a timed part of a step (#215). Ignored for a step this path
    /// doesn't show, like the installer's own changes are.
    func note(_ detail: Detail, under step: ProgressStep) {
        guard statuses[step] != nil else { return }
        details[step, default: []].append(detail)
    }

    /// Whether a step is still to come: the start that follows a repair or an
    /// update continues the same checklist rather than starting a new one.
    func isPending(_ step: ProgressStep) -> Bool {
        statuses[step] == .pending
    }

    var currentStep: ProgressStep? {
        steps.first { if case .running = statuses[$0] { return true } else { return false } }
    }

    var hasFailed: Bool {
        statuses.values.contains { if case .failed = $0 { return true } else { return false } }
    }

    /// What a step usually takes on this Mac, from its previous launches, or
    /// nil before there are any (#232).
    func usual(_ step: ProgressStep) -> Double? {
        ProgressEstimate.typicalSeconds(history: history[step] ?? [])
    }

    /// Follow the installer's own step list (`Installer.onStepChange`).
    /// Steps this path doesn't show are ignored.
    func apply(_ step: InstallStep, _ status: InstallStepStatus, at now: Date = Date()) {
        let mapped = ProgressStep(step)
        switch status {
        case .pending: break
        case .running: begin(mapped, at: now)
        case .completed: finish(mapped, at: now)
        case .skipped(let reason): skip(mapped, reason: reason)
        case .failed(let reason): fail(mapped, reason: reason)
        }
    }

    func states(at now: Date = Date()) -> [ProgressEstimate.StepState] {
        steps.map { step in
            let status: ProgressEstimate.StepState.Status
            switch statuses[step] ?? .pending {
            case .pending: status = .pending
            case .running(let since): status = .running(elapsed: now.timeIntervalSince(since))
            case .done(let seconds): status = .done(seconds: seconds)
            case .skipped(let reason): status = .skipped(reason: reason)
            case .failed: status = .failed
            }
            return ProgressEstimate.StepState(step: step, status: status)
        }
    }

    func estimate(at now: Date = Date()) -> ProgressEstimate.Estimate {
        ProgressEstimate.estimate(states(at: now), history: history)
    }

    /// Why the server start is slow, when it is and there is a reason (#228).
    func slowStartNotice(at now: Date = Date()) -> String? {
        ProgressEstimate.slowStartNotice(states(at: now))
    }

    func elapsed(at now: Date = Date()) -> Double {
        now.timeIntervalSince(startedAt)
    }
}

// MARK: - The server's own phases (#232)

extension InstallProgress {

    /// Follow a phase the backend reported on its standard output.
    ///
    /// `migrate` is part of "Starting the server". `pnl-update` becomes a step
    /// of its own the moment it begins — it can take minutes, and a step
    /// that reads "not needed" on every other launch would be noise. The
    /// import and the warm-up are the two steps after it. `ready` closes
    /// whatever is still running; /health follows it.
    func apply(_ phase: StartPhase, at now: Date = Date()) {
        guard statuses[.startServer] != nil else { return }
        sawServerPhases = true
        switch (phase.phase, phase.event) {
        case (.migrate, .begin):
            if statuses[.startServer] == .pending { begin(.startServer, at: now) }
        case (.migrate, .end), (.migrate, .skip):
            break
        case (.pnlUpdate, .begin):
            insert(.installPsyNeuLinkUpdate, after: .startServer)
            finish(.startServer, at: now)
            begin(.installPsyNeuLinkUpdate, at: now)
        case (.pnlUpdate, .end):
            finish(.installPsyNeuLinkUpdate, at: now)
        case (.pnlUpdate, .skip):
            break
        case (.importPsyNeuLink, .begin):
            finishServerStepsBefore(.loadPsyNeuLink, at: now)
            begin(.loadPsyNeuLink, at: now)
        case (.importPsyNeuLink, .end):
            finish(.loadPsyNeuLink, at: now)
        case (.importPsyNeuLink, .skip):
            finishServerStepsBefore(.loadPsyNeuLink, at: now)
            skip(.loadPsyNeuLink, reason: phase.detail ?? "already loaded")
        case (.warmWorker, .begin):
            finishServerStepsBefore(.warmModelRunner, at: now)
            begin(.warmModelRunner, at: now)
        case (.warmWorker, .end):
            finish(.warmModelRunner, at: now)
        case (.warmWorker, .skip):
            finishServerStepsBefore(.warmModelRunner, at: now)
            skip(.warmModelRunner, reason: phase.detail ?? "already warm")
        case (.ready, .begin), (.ready, .skip):
            break
        case (.ready, .end):
            for step in ProgressStep.allServerSteps where statuses[step] != nil {
                if case .running = statuses[step] { finish(step, at: now) }
            }
        }
        // The backend's own clock for the phase, for the report (#215).
        if phase.event == .end, let seconds = phase.elapsed {
            let under: ProgressStep = phase.step ?? .startServer
            let id = phase.phase == .ready ? "backend-total" : "backend/\(phase.phase.rawValue)"
            let title = phase.phase == .ready ? "backend: ready, total" : phase.title
            note(Detail(id: id, title: title, seconds: seconds, bytes: nil), under: under)
        }
    }

    /// The server answered /health: everything is up. Server steps still
    /// running finish now; ones never begun were covered by "Starting the
    /// server" on a backend that reports no phases, and are said to be —
    /// skipped with that reason, not hidden (#232).
    func serverAnsweredHealth(at now: Date = Date()) {
        guard statuses[.startServer] != nil else { return }
        for step in steps where ProgressStep.allServerSteps.contains(step) {
            switch statuses[step] ?? .pending {
            case .running:
                finish(step, at: now)
            case .pending:
                skip(step, reason: sawServerPhases ? nil : "counted in Starting the server")
            case .done, .skipped, .failed:
                break
            }
        }
    }

    /// Close the server steps that come before `step` in the list and are
    /// still running: a phase that begins ends the one before it even when
    /// the backend's `end` line was lost.
    private func finishServerStepsBefore(_ step: ProgressStep, at now: Date) {
        for earlier in steps.prefix(while: { $0 != step })
        where ProgressStep.allServerSteps.contains(earlier) {
            if case .running = statuses[earlier] { finish(earlier, at: now) }
        }
    }
}

// MARK: - For the report

extension InstallProgress {
    /// The checklist in words, for Report a Problem (#202), each step followed
    /// by its timed parts (#215), so a user's real timings reach us.
    func reportSteps(at now: Date = Date()) -> [ProblemReport.Step] {
        steps.flatMap { step -> [ProblemReport.Step] in
            let status: String
            switch statuses[step] ?? .pending {
            case .pending: status = "not reached"
            case .running(let since):
                status = String(format: "running for %.1f s", now.timeIntervalSince(since))
            case .skipped(let reason):
                status = reason.map { "not needed (\($0))" } ?? "not needed"
            case .done(let seconds): status = String(format: "done in %.1f s", seconds)
            case .failed(let reason): status = "failed: \(reason)"
            }
            let parts = (details[step] ?? []).map { d in
                ProblemReport.Step(title: "    \(d.title)", status: Self.describe(d))
            }
            return [ProblemReport.Step(title: step.title, status: status)] + parts
        }
    }

    /// "12.3 s", or "95.0 s, 310.2 MB downloaded".
    static func describe(_ d: Detail) -> String {
        var text = String(format: "%.1f s", d.seconds)
        if let bytes = d.bytes {
            text += ", \(InstallTimeline.format(bytes: bytes)) downloaded"
        }
        return text
    }

    /// Every step and detail with a time, for the boot report (#215): a step
    /// still running counts up to `now`, so a report written the moment the
    /// server answers still carries that step.
    func bootTimings(at now: Date = Date()) -> [BootReport.StepTiming] {
        var out: [BootReport.StepTiming] = []
        for step in steps {
            let seconds: Double?
            switch statuses[step] ?? .pending {
            case .running(let since): seconds = now.timeIntervalSince(since)
            case .done(let s): seconds = s
            case .pending, .skipped, .failed: seconds = nil
            }
            out.append(BootReport.StepTiming(id: step.rawValue, title: step.title, seconds: seconds, bytes: nil))
            for d in details[step] ?? [] {
                out.append(BootReport.StepTiming(
                    id: "\(step.rawValue)/\(d.id)", title: d.title, seconds: d.seconds, bytes: d.bytes))
            }
        }
        return out
    }
}
