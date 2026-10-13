import Foundation

/// How current the installed PsyNeuLink is, and whether to say anything. (#116)
///
/// The app installs PsyNeuLink from the Princeton `devel` branch, which reads as
/// "track the latest developer version". It doesn't: the branch is resolved once,
/// at install, and only re-pulled when the updater runs. One 0.5.5 install was
/// running a PsyNeuLink older than the then-current PyPI release while reporting
/// `devel`.
///
/// The decision made here is to *offer*, not to act. Silently re-pulling a moving
/// branch at launch would mean two runs of the same app version behaving
/// differently, which cuts against the isolation the 0.5.x work was for. So the
/// check runs in the background, startup never waits on it, and if the install is
/// behind the user is asked.
///
/// The comparison itself is not reimplemented here — the backend already exposes
/// it at `/api/settings/pnl-freshness`, so there is one implementation of "how far
/// behind" rather than two that can disagree.
struct PsyNeuLinkFreshness: Decodable {
    let status: String
    let behindBy: Int?
    let installedCommit: String?
    let headCommit: String?
    let headDate: String?
    let detail: String

    enum CodingKeys: String, CodingKey {
        case status
        case behindBy = "behind_by"
        case installedCommit = "installed_commit"
        case headCommit = "head_commit"
        case headDate = "head_date"
        case detail
    }
}

enum PsyNeuLinkUpdateOffer {
    /// Ask the user whether to update.
    case offer(behindBy: Int, headDate: String?)
    /// Say nothing: current, unknowable, not a branch install, or muted.
    case staySilent

    /// Whether an offer is warranted.
    ///
    /// Pure so the rules are testable without a network or a window. Four
    /// reasons to stay quiet, and the last two matter most:
    ///
    /// - the install is level with its branch, or pinned to a release;
    /// - the check could not reach GitHub — "couldn't tell" must never be
    ///   dressed up as "there is an update";
    /// - the user said not to ask again.
    static func decide(
        status: String,
        behindBy: Int?,
        headDate: String?,
        suppressed: Bool
    ) -> PsyNeuLinkUpdateOffer {
        if suppressed { return .staySilent }
        guard status == "behind" else { return .staySilent }
        guard let behindBy, behindBy > 0 else { return .staySilent }
        return .offer(behindBy: behindBy, headDate: headDate)
    }

    /// The sentence shown in the prompt.
    static func message(behindBy: Int, branch: String, headDate: String?) -> String {
        let commits = behindBy == 1 ? "commit" : "commits"
        var text = "The PsyNeuLink installed with PsyNeuView is \(behindBy) \(commits) "
            + "behind \(branch)."
        if let headDate, headDate.count >= 10 {
            text += " The newest is from \(headDate.prefix(10))."
        }
        text += "\n\nUpdating re-installs PsyNeuLink from \(branch) and restarts PsyNeuView."
        return text
    }
}

/// Fetches the freshness report from the running backend.
enum PsyNeuLinkFreshnessCheck {
    /// The endpoint on the local backend, for a given port.
    static func url(port: Int) -> URL? {
        URL(string: "http://127.0.0.1:\(port)/api/settings/pnl-freshness")
    }

    /// Ask the backend how current PsyNeuLink is.
    ///
    /// Returns nil on any failure. This is an optional courtesy; it must never
    /// be the reason a launch reports a problem.
    static func fetch(port: Int, timeout: TimeInterval = 8) async -> PsyNeuLinkFreshness? {
        guard let url = url(port: port) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(PsyNeuLinkFreshness.self, from: data)
        } catch {
            return nil
        }
    }
}

/// How the installed PsyNeuLink's age is described where the version is shown.
///
/// The other half of #116. The launch-time offer tells someone their install is
/// behind *if* they see it — but it can be muted, and it does not run when
/// there is no network. Settings would still say `Branch / ref: devel`, which
/// reads as current no matter how old the pin is. One install was 111 commits
/// and seven weeks behind while displaying exactly that.
///
/// So the age belongs next to the version, where someone looks when they want
/// to know what they are running.
enum PsyNeuLinkStaleness {
    case behind(String)
    /// Level with the branch, or not a branch install at all.
    case current(String)
    /// The check could not be made. Said out loud rather than hidden: "we do
    /// not know" is different from "it is fine", and silence reads as the
    /// second.
    case unknown(String)

    var text: String {
        switch self {
        case .behind(let t), .current(let t), .unknown(let t): return t
        }
    }

    var isBehind: Bool { if case .behind = self { return true }; return false }

    /// Describe a freshness result.
    ///
    /// Pure, so the wording is testable without a network. The backend already
    /// composes the sentence for the behind case — reusing it keeps one
    /// description of "how far behind" rather than two that can drift.
    static func describe(_ freshness: PsyNeuLinkFreshness?) -> PsyNeuLinkStaleness {
        guard let freshness else {
            return .unknown("Could not check how current this PsyNeuLink is.")
        }
        switch freshness.status {
        case "behind":
            let detail = freshness.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return .behind(detail.isEmpty
                ? "This PsyNeuLink is behind its branch."
                : detail)
        case "current":
            return .current("Up to date with its branch.")
        case "not_a_branch", "pinned":
            // A release or a pinned ref is not stale — it is what was asked for.
            return .current("Pinned to a release, so it does not track a branch.")
        default:
            let detail = freshness.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unknown(detail.isEmpty
                ? "Could not check how current this PsyNeuLink is."
                : detail)
        }
    }
}

