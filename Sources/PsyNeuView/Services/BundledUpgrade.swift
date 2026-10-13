import Foundation

/// Whether a launch should move to the PsyNeuView this app carries (#186).
///
/// Each bundled PsyNeuView unpacks into its own folder,
/// `…/Application Support/PsyNeuView/psyneuview-<version>`, and setup saves
/// that folder as the install. Nothing at launch ever compared it with the
/// archive inside the app, so an app update brought a new PsyNeuView that was
/// never used: every bundled user kept running the version they first
/// installed. One updated to 0.5.13 (bundling 0.5.8) and still had the old
/// Open menu and Settings.
///
/// Pure, so the rule is testable without unpacking anything.
enum BundledUpgrade {
    enum Decision: Equatable {
        /// Start from the folder in use.
        case stay
        /// Move to the version this app carries.
        case move(to: String)
    }

    /// - Parameters:
    ///   - isGitCheckout: the install is a clone; it updates by `git pull`.
    ///   - treeVersion: the version stamped in the folder in use, if any.
    ///   - archiveVersion: the version of the archive inside this app, if any.
    static func decide(
        isGitCheckout: Bool,
        treeVersion: String?,
        archiveVersion: String?
    ) -> Decision {
        // A checkout is the developer's own; it updates by pulling.
        guard !isGitCheckout else { return .stay }
        // A developer build with no archive has nothing to move to.
        guard let archiveVersion else { return .stay }
        // "Differs" rather than "newer": the PsyNeuView an app carries is the
        // one it was tested with, so even after a downgrade of the app, that's
        // the one to run. An unstamped folder is treated as different.
        return treeVersion == archiveVersion ? .stay : .move(to: archiveVersion)
    }
}
