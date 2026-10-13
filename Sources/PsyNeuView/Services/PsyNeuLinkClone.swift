import Foundation

/// Cloning a new PsyNeuLink checkout from the Setup Wizard (#190).
///
/// The wizard could use "a checkout I already have", but not make one, so
/// starting a second checkout (a fork, a feature branch) meant a trip to
/// Terminal first. The wizard now clones into a folder you choose, then
/// installs it in place exactly like an existing checkout.
///
/// The rules are pure and kept here, so they're testable without git or a
/// network: what to do with the chosen folder, whether a repository name is
/// usable, and the exact clone command.
enum PsyNeuLinkClone {
    static let defaultRepo = "PrincetonUniversity/PsyNeuLink"
    static let defaultBranch = "devel"

    enum Plan: Equatable {
        /// Clone into the folder (it doesn't exist yet, or is empty).
        case clone
        /// The folder already holds a PsyNeuLink checkout: use it, don't clone.
        case useExisting
        /// Can't go ahead, with why.
        case refuse(String)
    }

    /// What to do with the chosen destination folder.
    static func plan(destination: String, fileManager fm: FileManager = .default) -> Plan {
        let path = destination.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return .refuse("Choose a folder to clone into.") }
        if PsyNeuLinkSource.isValidLocalCheckout(path) { return .useExisting }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return .clone }
        guard isDir.boolValue else { return .refuse("That's a file, not a folder.") }
        let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        // A folder with only Finder's bookkeeping in it is as good as empty.
        let meaningful = contents.filter { $0 != ".DS_Store" }
        return meaningful.isEmpty
            ? .clone
            : .refuse("That folder isn't empty. Choose an empty or new folder, "
                      + "or one that already holds a PsyNeuLink checkout.")
    }

    /// `owner/name` on GitHub, e.g. `PrincetonUniversity/PsyNeuLink` or a fork.
    static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    static func isValidBranch(_ branch: String) -> Bool {
        let b = branch.trimmingCharacters(in: .whitespaces)
        return !b.isEmpty && !b.hasPrefix("-") && !b.contains(" ") && !b.contains("..")
    }

    /// Arguments for `git`. Full history, but file contents fetched on demand
    /// (`--filter=blob:none`), which makes PsyNeuLink's large history quick to
    /// clone while keeping `git log` and branches working.
    static func cloneArguments(repo: String, branch: String, destination: String) -> [String] {
        [
            "clone", "--filter=blob:none",
            "--branch", branch.trimmingCharacters(in: .whitespaces),
            "--",
            "https://github.com/\(repo.trimmingCharacters(in: .whitespaces)).git",
            destination.trimmingCharacters(in: .whitespaces),
        ]
    }
}
