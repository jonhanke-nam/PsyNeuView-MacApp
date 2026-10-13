import AppKit
import Foundation

/// Offer to move the app into /Applications before it builds anything.
///
/// A virtual environment records its interpreter by absolute path, and that
/// interpreter lives inside this bundle. Run from the mounted DMG or
/// ~/Downloads, finish setup, then drag the app to /Applications, and a 1.4 GB
/// environment is left pointing at a path that no longer exists — surfacing days
/// later as a startup failure with no visible connection to its cause.
///
/// Opening an app straight from its DMG is completely normal. Until now we
/// answered it with one line in a scrolling install log, which is the weakest
/// useful warning at the worst possible moment. (#109)
enum AppRelocation {

    /// Where the app is, and whether that is a problem.
    enum Location: Equatable, Sendable {
        /// In /Applications, or a system location. Nothing to do.
        case installed
        /// A read-only mounted image. Moving is the only sensible option —
        /// setup would otherwise build into a volume the user will eject.
        case diskImage(path: String)
        /// Downloads, Desktop, anywhere else writable.
        case elsewhere(path: String)
        /// Not an app bundle at all, so there is nothing here to relocate.
        /// `make run` is `swift run`, which produces a bare executable. (#166)
        case developmentBuild(path: String)

        var needsMoving: Bool {
            switch self {
            case .installed, .developmentBuild: return false
            case .diskImage, .elsewhere: return true
            }
        }
    }

    /// Classify a bundle path.
    ///
    /// Pure, so every branch is testable without moving anything.
    static func classify(bundlePath: String) -> Location {
        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        // Asked before anything about location, because "is this a bundle at
        // all" decides whether the rest of the question applies. A bare
        // executable has no bundle, and `Bundle.main.bundlePath` then reports
        // the directory the executable sits in — for `make run` that is
        // `.build/debug`, which classified as somewhere to move away from. The
        // prompt was only the visible half: accepting it took the last path
        // component as the app's name and would have copied the build
        // directory to `/Applications/debug`. (#166)
        if !path.hasSuffix(".app") {
            return .developmentBuild(path: path)
        }
        if path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") {
            return .installed
        }
        if path.hasPrefix("/Volumes/") {
            return .diskImage(path: path)
        }
        return .elsewhere(path: path)
    }

    /// What to tell the user, given where they are running from.
    ///
    /// Separate from the move itself so the wording is testable, and so the
    /// disk-image case can be stated more firmly than the Downloads case: one is
    /// a volume that will be ejected, the other merely a folder that may move.
    /// Whether launch-time prompts should be skipped entirely.
    ///
    /// Set `PSYNEUVIEW_NONINTERACTIVE=1` and the app takes the
    /// leave-things-alone answer to anything it would otherwise stop and ask,
    /// rather than blocking on a modal nobody is there to click.
    ///
    /// This exists because the prompts made the app untestable: any automated
    /// run — a smoke test, a startup-time measurement (#104), or someone
    /// driving a build to check a window — halts on the first dialog and waits
    /// for a human. The dialogs are right for a person and wrong for a script.
    ///
    /// Deliberately an environment variable rather than a stored setting: it
    /// applies to one launch, cannot be left switched on by accident, and a
    /// normal launch never has it set, so nothing changes for a real user.
    static var isNonInteractive: Bool {
        ProcessInfo.processInfo.environment["PSYNEUVIEW_NONINTERACTIVE"] == "1"
    }

    static func prompt(for location: Location) -> (title: String, body: String)? {
        switch location {
        case .installed, .developmentBuild:
            return nil
        case .diskImage:
            return (
                title: "Move PsyNeuView to Applications?",
                body: "PsyNeuView is running from a disk image. Setting it up here "
                    + "would install a large Python environment onto a volume you'll "
                    + "eject, and it would stop working as soon as you did.\n\n"
                    + "Moving it to your Applications folder takes a moment and avoids that."
            )
        case .elsewhere(let path):
            return (
                title: "Move PsyNeuView to Applications?",
                body: "PsyNeuView is running from \(path).\n\n"
                    + "Its Python environment records where the app lives, so moving "
                    + "the app later would strand it and force a rebuild. Moving it now "
                    + "avoids that."
            )
        }
    }

    enum MoveError: LocalizedError {
        case destinationExists(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .destinationExists(let path):
                return "There is already an app at \(path). Replace it yourself, "
                     + "then open PsyNeuView from Applications."
            case .failed(let detail):
                return "Couldn't move PsyNeuView to Applications: \(detail)"
            }
        }
    }

    /// Copy the bundle into /Applications and return where it landed.
    ///
    /// A copy rather than a move: the source may be a read-only disk image, and
    /// a half-moved app is worse than one still on the DMG.
    static func moveToApplications(
        from bundlePath: String,
        into applicationsDirectory: String = "/Applications"
    ) throws -> String {
        let source = URL(fileURLWithPath: bundlePath)
        let destination = URL(fileURLWithPath: applicationsDirectory)
            .appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            throw MoveError.destinationExists(destination.path)
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw MoveError.failed(error.localizedDescription)
        }
        return destination.path
    }

    /// Relaunch from the new location and exit this copy.
    static func relaunch(at path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
