import Foundation

/// Whether "Update PsyNeuView checkout…" may pull, and what to say when it
/// may not (#214).
///
/// The pull is the same one PsyNeuView makes for its per-checkout PsyNeuLink
/// sources: fast-forward only, on the branch the checkout is already on, and
/// never over uncommitted work. A checkout is someone's working folder; a
/// merge commit it did not ask for, or a pull that collides with edits in
/// progress, is the kind of help that costs an afternoon. When the pull is
/// refused, the reason is said in the log window, in words that name what to
/// do about it.
///
/// The decision is a pure function over `State`, so it can be tested without
/// a repository; `Updater.pullReadiness` is the one place that reads one.
enum CheckoutPull {

    /// What `git` reported about the checkout, read once.
    struct State: Equatable {
        /// The branch the checkout is on; nil for a detached HEAD.
        var branch: String?
        /// Whether `git fetch origin <branch>` succeeded, so `behind` and
        /// `ahead` are about the remote as it is now.
        var fetched: Bool
        /// Tracked files with uncommitted changes (staged or not). Untracked
        /// files are not counted: a fast-forward never touches them.
        var changedFiles: Int
        /// Local commits that are not on origin's branch.
        var ahead: Int
        /// Commits on origin's branch that are not here.
        var behind: Int
        /// The checkout and origin's branch share no history at all (`git
        /// merge-base` finds none). That is what an old checkout sees after
        /// PsyNeuView moved to a fresh public repository on 2026-10-13: the
        /// same URL now holds unrelated history.
        var unrelated: Bool = false
    }

    /// Said when the histories are unrelated: what happened, and both ways on.
    static let unrelatedHistoryMessage =
        "This checkout's history isn't related to origin's: PsyNeuView moved to a fresh "
        + "public repository (github.com/jonhanke-nam/PsyNeuView) on 2026-10-13; not pulled. "
        + "Clone it again to follow the public repository, or point origin at "
        + "github.com/jonhanke-nam/PsyNeuView-archive to stay on the old history."

    enum Decision: Equatable {
        /// Fast-forward `branch` to origin's copy of it.
        case pull(branch: String)
        /// Nothing to bring in, and why — not a failure.
        case nothingToPull(String)
        /// Must not pull, and why, in words for the log.
        case refuse(String)
    }

    static func decide(_ state: State) -> Decision {
        guard let branch = state.branch, !branch.isEmpty else {
            return .refuse(
                "The checkout isn't on a branch (detached HEAD); not pulled. "
                + "Check out a branch first.")
        }
        let remote = "origin/\(branch)"
        guard state.fetched else {
            return .refuse(
                "Couldn't fetch \(remote) to check for updates; not pulled. "
                + "Check the network and the remote, then try again.")
        }
        if state.unrelated {
            return .refuse(unrelatedHistoryMessage)
        }
        if state.changedFiles > 0 {
            let files = state.changedFiles == 1 ? "1 file" : "\(state.changedFiles) files"
            return .refuse(
                "\(files) changed locally; not pulled. "
                + "Commit or stash the changes in the checkout first.")
        }
        if state.ahead > 0 && state.behind > 0 {
            return .refuse(
                "\(branch) has diverged from \(remote) "
                + "(\(commits(state.ahead)) here, \(commits(state.behind)) on origin); not pulled. "
                + "Rebase or merge in the checkout by hand.")
        }
        if state.ahead > 0 {
            return .nothingToPull(
                "\(branch) is \(commits(state.ahead)) ahead of \(remote); nothing to pull.")
        }
        if state.behind == 0 {
            return .nothingToPull("\(branch) is up to date with \(remote).")
        }
        return .pull(branch: branch)
    }

    /// `git rev-list --left-right --count HEAD...origin/<branch>` prints
    /// "<ahead>\t<behind>". Anything else reads as nil, which callers treat as
    /// "cannot tell" rather than as zero.
    static func counts(fromRevList output: String) -> (ahead: Int, behind: Int)? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else {
            return nil
        }
        return (ahead, behind)
    }

    /// `git status --porcelain --untracked-files=no` prints one line per
    /// changed tracked file.
    static func changedFiles(fromStatus output: String) -> Int {
        output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private static func commits(_ n: Int) -> String {
        n == 1 ? "1 commit" : "\(n) commits"
    }
}
