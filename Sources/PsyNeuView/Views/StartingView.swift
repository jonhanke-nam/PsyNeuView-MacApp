import SwiftUI

/// Shown while the backend boots, so a finished setup hands the user the app
/// rather than a debug log.
///
/// Setup used to end on the log window — opened deliberately, to stop macOS
/// quitting when the wizard closed and nothing else was open — and the real
/// window only appeared once the backend passed its health check and PsyNeuLink
/// finished importing. That gap is tens of seconds, and during it the entire
/// product was a scrolling list of internal messages with no indication that
/// anything else existed. (#96)
struct StartingView: View {
    /// What the app is doing, in the user's terms rather than the log's.
    let status: String
    /// Set when startup has failed, so the window says so instead of spinning
    /// forever — the old behaviour made "still working" and "broken" look
    /// identical.
    let failure: String?
    let onShowLogs: () -> Void
    /// Nil when trying again cannot help — a process that has exited is not
    /// coming back on its own, and offering the button anyway is what made one
    /// install log "Cannot start" four times (#101, #104).
    let onRetry: (() -> Void)?
    /// The steps, their times and the time left (#196). Nil shows the
    /// spinner alone.
    var progress: InstallProgress? = nil
    /// Report a Problem (#202), offered when startup has failed.
    var onReport: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if failure == nil, let progress {
                Text("Starting PsyNeuView")
                    .font(.title2)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                InstallProgressView(progress: progress, onShowLogs: onShowLogs)
                    .frame(maxWidth: 460)
            } else if failure == nil {
                ProgressView().controlSize(.large)
                Text("Starting PsyNeuView")
                    .font(.title2)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text("The first start takes longer while PsyNeuLink loads.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("PsyNeuView didn't start")
                    .font(.title2)
                Text(failure ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                // Which step it stopped at (#196).
                if let progress {
                    InstallProgressView(progress: progress, onShowLogs: nil)
                        .frame(maxWidth: 460)
                }
                HStack(spacing: 12) {
                    Button("Show Logs", action: onShowLogs)
                    if let onReport {
                        Button("Report a Problem…", action: onReport)
                    }
                    if let onRetry {
                        Button("Try Again", action: onRetry)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 4)
            }

            Spacer()

            if failure == nil {
                Button("Show Logs", action: onShowLogs)
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
