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
/// a repository; `Updater.pullState` is the one place that reads one.
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
        /// merge-base` finds none). That is what an existing checkout sees
        /// when PsyNeuView's repository history is rebuilt: the same URL now
        /// holds a history whose commits all have new IDs.
        var unrelated: Bool = false
    }

    /// Said when the histories are unrelated: what happened, and the way on.
    /// A launch only says it; "Update PsyNeuView checkout…" offers to do it.
    static func unrelatedHistoryMessage(_ state: State) -> String {
        let what = "This checkout's history isn't related to origin's: PsyNeuView's "
            + "repository history was rebuilt, so its commits have new IDs; not pulled. "
        if state.changedFiles > 0 {
            return what + "Commit or stash the local changes, then choose "
                + "“Update PsyNeuView checkout…” to move this checkout to the new history."
        }
        return what + "Choose “Update PsyNeuView checkout…” to move this checkout to the "
            + "new history; its own commits are kept on a backup branch."
    }

    /// Whether the checkout may be moved onto origin's rebuilt history (when
    /// the user asks): the histories are unrelated, origin was just fetched,
    /// it is on a branch, and nothing tracked is changed. Untracked files are
    /// left alone by the move (`git reset --keep`), which refuses rather than
    /// overwrite one.
    static func mayAdoptNewHistory(_ state: State) -> Bool {
        state.unrelated && state.fetched && state.changedFiles == 0
            && !(state.branch ?? "").isEmpty
    }

    /// Where the checkout's own commits are kept when it moves to the new
    /// history: `old-history/<branch>-<yyyymmdd>`.
    static func backupBranch(for branch: String, on date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return "old-history/\(branch)-\(f.string(from: date))"
    }

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
            return .refuse(unrelatedHistoryMessage(state))
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
