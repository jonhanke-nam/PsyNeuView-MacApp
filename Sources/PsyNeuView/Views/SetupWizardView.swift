import SwiftUI
import AppKit

enum SetupStep: Int, CaseIterable {
    case welcome = 0
    case install = 1
    case done = 2

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .install: return "Setting Up"
        case .done: return "Ready"
        }
    }
}

@MainActor
struct SetupWizardView: View {
    let preferences: Preferences
    let onComplete: () -> Void

    @State private var currentStep: SetupStep = .welcome
    @State private var installer = Installer()
    /// Steps, times and time left for the install (#196).
    @State private var progress: InstallProgress?
    @State private var isInstalling = false
    /// Ticked by the user before we will build inside an existing checkout. (#69)
    @State private var adoptionAcknowledged = false
    @State private var installSuccess = false
    @State private var installOutput = ""
    @State private var repoPath: URL = AppIdentity.current.defaultCheckoutDirectory()

    /// Which PsyNeuLink to install (#130).
    ///
    /// Held here and passed straight to the install, not written to
    /// preferences. After setup the backend owns this — the app asking it
    /// rather than remembering it is the whole point of #132 — and a wizard
    /// that stored the answer would put the second copy straight back.
    // Shared with UnattendedSetup, so a launch nobody answers installs what
    // clicking straight through here would (#174).
    @State private var pnlChoice: PsyNeuLinkChoice = PsyNeuLinkChoice(UnattendedSetup.defaultSource)
    @State private var pnlBranch: String = UnattendedSetup.defaultBranch
    @State private var pnlLocalPath: String = ""
    // "Clone a new checkout" (#190).
    @State private var cloneDestination: String = ""
    @State private var cloneRepo: String = PsyNeuLinkClone.defaultRepo
    @State private var cloneBranch: String = PsyNeuLinkClone.defaultBranch

    /// What gets installed. A new clone installs exactly like an existing
    /// checkout once it's on disk.
    private var pnlSource: PsyNeuLinkSource { pnlChoice.source }

    /// The pip arguments for the chosen source.
    private var chosenPipArgs: [String] {
        pnlSource.pipInstallArgs(
            branch: pnlBranch, repo: "", localPath: pnlLocalPath)
    }

    /// Whether setup installs the PsyNeuView this app carries.
    private var installsBundled: Bool {
        preferences.useBundledApp && BundledPsyNeuView.archiveURL() != nil
    }

    private var clonePlan: PsyNeuLinkClone.Plan {
        PsyNeuLinkClone.plan(destination: cloneDestination)
    }

    /// Whether the choice is complete enough to install.
    private var pnlChoiceIsUsable: Bool {
        switch pnlChoice {
        case .github, .pypi:
            return true
        case .existing:
            return PsyNeuLinkSource.isValidLocalCheckout(pnlLocalPath)
        case .clone:
            if case .refuse = clonePlan { return false }
            return PsyNeuLinkClone.isValidRepo(cloneRepo)
                && PsyNeuLinkClone.isValidBranch(cloneBranch)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            StepIndicatorView(currentStep: currentStep)
                .padding(.vertical, 16)

            Divider()

            // Content
            Group {
                switch currentStep {
                case .welcome:
                    // Scrolls, so the button row below is always reachable,
                    // whatever the PsyNeuLink choice adds (#193).
                    ScrollView { welcomeView.padding(.vertical, 4) }
                case .install:
                    installView
                case .done:
                    doneView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)


            Divider()

            // Navigation
            HStack {
                if currentStep == .welcome {
                    Spacer()
                    Button("Get Started") {
                        currentStep = .install
                        Task { await runInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled((needsAdoptionAcknowledgement && !adoptionAcknowledged)
                              // A local checkout that is not one fails deep inside
                              // pip, where the error explains nothing (#130).
                              || !pnlChoiceIsUsable)
                } else if currentStep == .done {
                    Spacer()
                    Button("Launch PsyNeuView") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                }
            }
            .padding(16)
        }
        // A minimum, not a fixed size: a fixed 700×520 is how Get Started ended
        // up below the window's edge once a checkout's folder field appeared (#193).
        .frame(minWidth: 700, idealWidth: 700, minHeight: 560, idealHeight: 640)
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Welcome to PsyNeuView")
                .font(.title)

            Text("PsyNeuView will be set up automatically. This includes:")
                .foregroundStyle(.secondary)

            // What setup will actually do: the bundled install needs no
            // developer tools, Node.js or GitHub sign-in (#191).
            VStack(alignment: .leading, spacing: 8) {
                ForEach(WizardText.steps(bundled: installsBundled), id: \.text) { step in
                    SetupItem(icon: step.icon, text: step.text)
                }
            }
            .padding(.horizontal, 40)

            // Offered here because this is the moment someone is watching the
            // install and wondering why it is not using the PsyNeuLink they
            // already have. It was only reachable afterwards, in Settings —
            // by which point they have waited through an install they did not
            // want (#130).
            VStack(alignment: .leading, spacing: 6) {
                Picker("PsyNeuLink:", selection: $pnlChoice) {
                    ForEach([PsyNeuLinkChoice.github, .pypi, .existing, .clone], id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)

                // Which choices give you files you can edit (#191).
                Text(pnlChoice.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if pnlChoice == .clone {
                    HStack {
                        TextField("Folder to clone into", text: $cloneDestination)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { selectCloneDestination() }
                    }
                    HStack {
                        TextField("Repository", text: $cloneRepo)
                            .textFieldStyle(.roundedBorder)
                        TextField("Branch", text: $cloneBranch)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                    Text(cloneHint)
                        .font(.caption)
                        .foregroundStyle(pnlChoiceIsUsable ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if pnlChoice == .existing {
                    HStack {
                        TextField("PsyNeuLink folder", text: $pnlLocalPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") { selectPsyNeuLinkDirectory() }
                    }
                    Text(pnlLocalPathHint)
                        .font(.caption)
                        .foregroundStyle(pnlChoiceIsUsable ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 4)

            Text("This may take 5–10 minutes on first run.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Install location. In bundled mode the app owns the directory, so
            // offering a picker it will ignore would be a lie. (#74)
            if installsBundled {
                Text("PsyNeuView is included in this app — no GitHub account needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                if needsAdoptionAcknowledgement {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(existingFolderTitle)
                            .font(.callout).bold()
                        Text(existingFolderDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Use this folder", isOn: $adoptionAcknowledged)
                            .font(.caption)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                }
                HStack {
                    Text("Install to:")
                        .foregroundStyle(.secondary)
                    Text(repoPath.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change...") {
                        selectDirectory()
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Install

    private var installView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setting up PsyNeuView...")
                .font(.headline)

            // Only the steps this install runs, with their times and the
            // time left (#196).
            if let progress {
                InstallProgressView(progress: progress, onShowLogs: nil)
            }

            // Log output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(installOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logBottom")
                }
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.05)))
                .onChange(of: installOutput) { _, _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }

        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("PsyNeuView is ready!")
                .font(.title2)
            Text("Click Launch to start.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Install Location"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url
            // A new choice needs its own acknowledgement.
            adoptionAcknowledged = false
        }
    }

    /// True when we'd build inside a checkout the user already had. Only ever
    /// true on the clone path — a bundled install owns its own directory. (#69)
    /// What is already in the chosen folder, or `.clear` when the app owns the
    /// directory and the question does not arise.
    private var existingContents: BundledPsyNeuView.ExistingContents {
        guard !(preferences.useBundledApp && BundledPsyNeuView.archiveURL() != nil) else {
            return .clear
        }
        return BundledPsyNeuView.existingContents(at: repoPath)
    }

    /// Split out of the view body deliberately.
    ///
    /// These were inline ternaries inside the `VStack`. The debug build was
    /// fine; the release build failed with "unable to type-check this
    /// expression in reasonable time" — SwiftUI's builder plus string
    /// concatenation plus a ternary is enough to defeat the checker at higher
    /// optimisation. Plain properties cost nothing and cannot regress that way.
    private var existingFolderTitle: String {
        existingContents == .psyNeuViewCheckout
            ? "That folder already contains PsyNeuView."
            : "That folder already has files in it."
    }

    private var existingFolderDetail: String {
        if existingContents == .psyNeuViewCheckout {
            return "Setup will use it as-is: a Python environment will be created "
                + "inside it at backend/.venv, and dependencies installed there. "
                + "Your files won't be modified, but the folder won't be left "
                + "exactly as you found it."
        }
        return "Setup will install into it: a Python environment will be created "
            + "inside it at backend/.venv, and PsyNeuView's own files added "
            + "alongside what is already there. Nothing you have will be "
            + "deleted, but this folder will no longer be only yours."
    }


    /// What to say under the folder field.
    private var pnlLocalPathHint: String {
        if pnlLocalPath.isEmpty {
            return "Choose the folder containing your PsyNeuLink checkout. "
                + "It is installed in place, so your own tools keep using it."
        }
        return pnlChoiceIsUsable
            ? "Looks like a PsyNeuLink checkout."
            : "That folder does not look like a PsyNeuLink checkout — "
                + "expected psyneulink/ and setup.py inside it."
    }

    /// What to say under the clone fields.
    private var cloneHint: String {
        if !PsyNeuLinkClone.isValidRepo(cloneRepo) {
            return "Repository should be owner/name on GitHub, like \(PsyNeuLinkClone.defaultRepo)."
        }
        if !PsyNeuLinkClone.isValidBranch(cloneBranch) {
            return "Enter a branch, like \(PsyNeuLinkClone.defaultBranch)."
        }
        switch clonePlan {
        case .refuse(let why):
            return why
        case .useExisting:
            return "That folder already holds a PsyNeuLink checkout. It will be used as it is, not cloned again."
        case .clone:
            return "PsyNeuLink will be cloned here, then installed in place, so your own tools "
                + "can use the same files. Cloning needs git and a network connection."
        }
    }

    private func selectCloneDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Clone Here"
        panel.message = "Choose an empty folder (or make a new one) for the PsyNeuLink checkout."
        if panel.runModal() == .OK, let url = panel.url {
            cloneDestination = url.path
        }
    }

    /// Clone, if that's the choice, and point the install at the result (#190).
    /// Returns false when cloning was needed and failed.
    private func cloneIfChosen() async -> Bool {
        guard pnlChoice == .clone else { return true }
        let destination = cloneDestination.trimmingCharacters(in: .whitespaces)
        switch clonePlan {
        case .refuse(let why):
            installOutput += "Can't clone: \(why)\n"
            progress?.fail(.clonePsyNeuLink, reason: why)
            return false
        case .useExisting:
            installOutput += "Using the PsyNeuLink checkout already at \(destination).\n"
            pnlLocalPath = destination
            progress?.finish(.clonePsyNeuLink)
            return true
        case .clone:
            break
        }
        progress?.begin(.clonePsyNeuLink)
        guard await Shell.which("git") != nil,
              (try? await Shell.run("/usr/bin/xcode-select", arguments: ["-p"]))?.exitCode == 0
        else {
            installOutput += "Cloning needs git, which comes with Apple's Command Line Tools, "
                + "and they aren't installed. Choose another PsyNeuLink option, "
                + "or install the Command Line Tools and run setup again.\n"
            progress?.fail(.clonePsyNeuLink, reason: "git isn't installed")
            return false
        }
        installOutput += "Cloning \(cloneRepo) (\(cloneBranch)) into \(destination)...\n"
        let status = await Shell.runStreaming(
            "git",
            arguments: PsyNeuLinkClone.cloneArguments(
                repo: cloneRepo, branch: cloneBranch, destination: destination),
            onOutput: { text in
                Task { @MainActor in installOutput += text }
            })
        guard status == 0, PsyNeuLinkSource.isValidLocalCheckout(destination) else {
            installOutput += "Cloning failed (git exited with \(status)). "
                + "Check the repository, the branch and your network connection.\n"
            progress?.fail(.clonePsyNeuLink, reason: "git exited with \(status)")
            return false
        }
        progress?.finish(.clonePsyNeuLink)
        installOutput += "Cloned. Installing it in place.\n"
        pnlLocalPath = destination
        return true
    }

    private func selectPsyNeuLinkDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            pnlLocalPath = url.path
        }
    }

    private var needsAdoptionAcknowledgement: Bool {
        existingContents != .clear
    }

    private func runInstall() async {
        isInstalling = true

        // In bundled mode the app owns the directory — nothing to create, and
        // the chosen path is irrelevant. (#74)
        let useBundled = preferences.useBundledApp && BundledPsyNeuView.archiveURL() != nil
        var needsClone = false
        if !useBundled {
            try? FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
            let makefile = repoPath.appendingPathComponent("Makefile")
            needsClone = !FileManager.default.fileExists(atPath: makefile.path)
        }

        installer.onOutput = { text in
            installOutput += text + "\n"
        }
        let tracker = InstallProgress.recorded(ProgressPlan.steps(
            for: useBundled ? .bundledSetup : .checkoutSetup,
            clonesPsyNeuLink: pnlChoice == .clone))
        progress = tracker
        installer.onStepChange = { step, status in tracker.apply(step, status) }

        guard await cloneIfChosen() else {
            isInstalling = false
            installSuccess = false
            return
        }

        installSuccess = await installer.installAll(
            repoPath: repoPath,
            needsClone: needsClone,
            // The wizard's own choice, not a stored preference (#130).
            pnlPipArgs: chosenPipArgs,
            useBundled: useBundled
        )

        // Persist where the install actually landed, which in bundled mode is the
        // unpacked tree rather than anything the user picked.
        if installSuccess {
            preferences.repoPath = installer.resolvedRepoPath ?? repoPath
        }
        isInstalling = false

        if installSuccess {
            currentStep = .done
        }
    }
}

struct SetupItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(text)
        }
    }
}

struct StepIndicatorView: View {
    let currentStep: SetupStep

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                HStack(spacing: 4) {
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                }
                if step != SetupStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: 60)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

/// The wizard's PsyNeuLink choices. A new clone is a fourth way to get a local
/// checkout, so it installs as `.local` once it's on disk (#190).
enum PsyNeuLinkChoice: Hashable {
    case github, pypi, existing, clone

    init(_ source: PsyNeuLinkSource) {
        switch source {
        case .github: self = .github
        case .pypi: self = .pypi
        case .local: self = .existing
        }
    }

    var source: PsyNeuLinkSource {
        switch self {
        case .github: return .github
        case .pypi: return .pypi
        case .existing, .clone: return .local
        }
    }
}
