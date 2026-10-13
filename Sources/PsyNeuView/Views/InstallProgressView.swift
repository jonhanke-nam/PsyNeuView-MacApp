import SwiftUI

/// The one progress view for installing and starting (#196): a checklist of
/// steps with how long each took, total time so far, a time-remaining range
/// with a bar for the step in progress, and a plain word when a step runs
/// over its usual time.
///
/// Used by the Setup Wizard's install step, the starting window, and the
/// update to a new included PsyNeuView (#186). A spinner and "still
/// starting" looked the same as a hang (#185); this shows what is happening.
@MainActor
struct InstallProgressView: View {
    let progress: InstallProgress
    /// Nil where the log is already on screen (the wizard shows it below).
    var onShowLogs: (() -> Void)?

    var body: some View {
        // Once a second: the elapsed times and the estimate move with the clock.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let estimate = progress.estimate(at: now)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(progress.states(at: now), id: \.step) { state in
                    row(state)
                }
            }

            if !progress.hasFailed {
                if let fraction = estimate.currentFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Current step")
                }
                HStack {
                    Text("Elapsed \(ProgressEstimate.clock(progress.elapsed(at: now)))")
                    Spacer()
                    if progress.currentStep != nil {
                        Text(ProgressEstimate.phrase(estimate))
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

                // Why the first start after new packages is slow (#228).
                if let notice = progress.slowStartNotice(at: now) {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if estimate.overrunning {
                    overrunNotice(stalled: estimate.stalled)
                }
            }
        }
    }

    private func row(_ state: ProgressEstimate.StepState) -> some View {
        HStack(spacing: 8) {
            icon(state.status)
                .frame(width: 16)
            Text(state.step.title)
                .foregroundStyle(titleStyle(state.status))
            Spacer(minLength: 12)
            Text(detail(state))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Pending and skipped steps read quieter than ones that ran.
    private func titleStyle(_ status: ProgressEstimate.StepState.Status) -> HierarchicalShapeStyle {
        switch status {
        case .pending, .skipped: return .secondary
        case .running, .done, .failed: return .primary
        }
    }

    @ViewBuilder private func icon(_ status: ProgressEstimate.StepState.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "circle.inset.filled").foregroundStyle(Color.accentColor)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    /// The right-hand column: the clock for a step that ran, and for one in
    /// progress what it usually takes on this Mac (#232); for one not
    /// needed, why ("already up to date").
    private func detail(_ state: ProgressEstimate.StepState) -> String {
        switch state.status {
        case .pending:
            return ""
        case .running(let elapsed):
            let clock = ProgressEstimate.clock(elapsed)
            guard let usual = progress.usual(state.step) else { return clock }
            return "\(clock) · \(ProgressEstimate.usualPhrase(seconds: usual))"
        case .done(let seconds):
            return ProgressEstimate.clock(seconds)
        case .skipped(let reason):
            return reason.map { "skipped — \($0)" } ?? "not needed"
        case .failed:
            return "failed"
        }
    }

    /// A plain property, not a ternary in the view body: those defeat the
    /// release build's type checker (see SetupWizardView).
    private var stalledAdvice: String {
        let whereToLook = onShowLogs == nil ? "The log below shows" : "Show Logs shows"
        return "This is much longer than usual. \(whereToLook) whether it is still doing "
            + "something. If it has stopped, quit PsyNeuView and open it again to try once more."
    }

    @ViewBuilder private func overrunNotice(stalled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Taking longer than usual — still working.", systemImage: "hourglass")
                    .foregroundStyle(.orange)
                if let onShowLogs {
                    Button("Show Logs", action: onShowLogs)
                        .controlSize(.small)
                }
            }
            if stalled {
                Text(stalledAdvice)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .font(.caption)
    }
}
