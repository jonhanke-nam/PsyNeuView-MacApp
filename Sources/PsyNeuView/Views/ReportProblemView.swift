import AppKit
import SwiftUI

/// Report a Problem (#202), shown inside the Logs window.
///
/// Not a window of its own: per PsyNeuView-archive#1279 the Logs window is one of the
/// few native windows allowed, because it must work when PsyNeuView can't
/// start, and that's exactly when this is needed.
///
/// Borrowed from Feedback Assistant: gather automatically, list every
/// attachment with a way to view or remove it, let people add files, give a
/// reference to quote, and say plainly how to send it.
@MainActor
struct ReportProblemView: View {
    @Bindable var model: ProblemReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Report a Problem").font(.title2.weight(.semibold))
                Spacer()
                Button("Back to Logs") { model.close() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                Group {
                    if model.saved == nil {
                        compose
                    } else {
                        howToSend
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Before saving

    private var compose: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What happened?").font(.headline)
                editor($model.whatHappened, height: 80)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What did you expect? (optional)").font(.headline)
                editor($model.expected, height: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What's included").font(.headline)
                ForEach($model.shots) { $shot in
                    IncludedRow(
                        isOn: $shot.included,
                        title: shot.source == "The app window"
                            ? "Screenshot of the app window" : "Screenshot: \(shot.source)",
                        image: shot.image)
                }
                if model.shots.isEmpty, let note = model.screenshotNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Button("Add another screenshot…") { model.addScreenshots() }
                    .buttonStyle(.link)
                ForEach(model.offeredParts) { part in
                    IncludedRow(
                        isOn: Binding(
                            get: { model.included.contains(part) },
                            set: { on in
                                if on { model.included.insert(part) } else { model.included.remove(part) }
                            }),
                        title: part.title,
                        text: { model.preview(part) })
                }
                if let outcome = model.pageDiagnostics {
                    if outcome.provided == nil {
                        Text(outcome.note).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Asking PsyNeuView for its diagnostics…").font(.callout).foregroundStyle(.secondary)
                }
                Text("Tokens and passwords are always removed, and your home folder is shown as ~.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Text("Saved to your Downloads folder as a PNV-debugging folder, with a .zip beside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save Report") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
    }

    // MARK: After saving

    @ViewBuilder
    private var howToSend: some View {
        let plan = model.sendPlan
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved \(model.savedRequest?.reference ?? "")")
                        .font(.headline)
                        .textSelection(.enabled)
                    if let folder = model.saved?.folder {
                        Text(InstallSwitch.abbreviated(folder.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Show in Finder") { model.showInFinder() }
            }

            Text(model.instructions)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Quote the folder's name, \(model.savedRequest?.reference ?? ""), if you write about it later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let notice = plan.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(model.copiedSummary ? "Copied" : "Copy summary") { model.copySummary() }
                ShareButton { view in model.share(from: view) }
                    .fixedSize()
                sendButton("Email", preferred: plan.preferred == .email) { model.email() }
                    .disabled(!plan.emailAvailable)
                    .help(plan.emailAvailable
                          ? "Opens your mail app with the report attached."
                          : "No mail app is set up on this Mac.")
                sendButton("Gmail", preferred: plan.preferred == .gmail) { model.gmail() }
                    .help("Opens Gmail in your browser. Attach the folder from Downloads there.")
            }

            if model.developerMode() && ProblemReport.githubIssuesEnabled {
                HStack(spacing: 10) {
                    Text("Developer:").font(.callout).foregroundStyle(.secondary)
                    ForEach(ProblemReport.IssueRepo.allCases) { repo in
                        Button("Open as GitHub issue in \(repo.title)") { model.openIssue(in: repo) }
                    }
                }
                Text("GitHub can't attach files through a link: drag the screenshot in from the folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Button("New Report") {
                    model.reset()
                    model.takeScreenshot()
                    model.askThePage()
                }
                Spacer()
                Button("Done") { model.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func sendButton(_ title: String, preferred: Bool, action: @escaping () -> Void) -> some View {
        if preferred {
            Button(title, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(title, action: action)
        }
    }
}

/// One attachment: a checkbox to keep it, and View to see exactly what's sent.
@MainActor
private struct IncludedRow: View {
    @Binding var isOn: Bool
    let title: String
    var image: NSImage? = nil
    var text: (() -> String)? = nil
    @State private var showing = false
    @State private var shown = ""

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn).toggleStyle(.checkbox)
            Spacer()
            Button("View") {
                if let text { shown = text() }
                showing = true
            }
            .buttonStyle(.link)
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 560, maxHeight: 400)
                        .padding(8)
                } else {
                    ScrollView {
                        Text(shown)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(width: 560, height: 320)
                }
            }
        }
    }
}

/// Share…, anchored to the button so the share sheet opens beside it.
@MainActor
private struct ShareButton: NSViewRepresentable {
    let onShare: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onShare = onShare
    }

    func makeCoordinator() -> Coordinator { Coordinator(onShare: onShare) }

    final class Coordinator: NSObject {
        var onShare: (NSView) -> Void
        init(onShare: @escaping (NSView) -> Void) { self.onShare = onShare }
        @objc func share(_ sender: NSButton) { onShare(sender) }
    }
}
