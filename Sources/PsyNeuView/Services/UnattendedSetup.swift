import Foundation

/// First launch with nobody at the keyboard (#174).
///
/// A first launch shows the Setup Wizard and waits for someone to press
/// Install. The release's launch check starts the built app on a fresh CI
/// runner, where nobody ever will — so the app sat on the wizard, never started
/// its server, and the check timed out without a word about why.
///
/// With `PSYNEUVIEW_NONINTERACTIVE=1` and a bundled PsyNeuView to install, the
/// app now does what the wizard does when you accept every default: install the
/// bundled tree, then start. That is a real user's first launch, minus the
/// clicks, which is what the launch check means to test.
///
/// A normal launch never has the variable set, so nothing changes for users.
enum UnattendedSetup {
    /// The wizard's default PsyNeuLink choice: GitHub, `devel` (#47). The
    /// wizard starts from these, so an unattended install matches what someone
    /// clicking straight through would get.
    static let defaultSource: PsyNeuLinkSource = .github
    static let defaultBranch = "devel"

    static var defaultPipArgs: [String] {
        defaultSource.pipInstallArgs(branch: defaultBranch)
    }

    /// Whether a launch with no setup should install by itself rather than
    /// show the wizard. Only when nobody can answer the wizard, and only from a
    /// bundled PsyNeuView: cloning needs choices the defaults can't make.
    static func shouldInstall(
        setupCompleted: Bool,
        nonInteractive: Bool,
        useBundledApp: Bool,
        hasBundledArchive: Bool
    ) -> Bool {
        !setupCompleted && nonInteractive && useBundledApp && hasBundledArchive
    }
}
