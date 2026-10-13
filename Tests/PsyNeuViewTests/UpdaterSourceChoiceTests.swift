import Foundation
import XCTest
@testable import PsyNeuView

/// Which pip arguments an update refreshes with (#132, #116).
///
/// Extracted from `Updater` so the decision can be tested without running pip.
/// The case that matters is the one that nearly shipped: the backend reports an
/// editable checkout with a GitHub origin as `source: "github"`, and believing
/// that would replace a live local checkout with a fresh clone.
final class UpdaterSourceChoiceTests: XCTestCase {

    private func current(
        source: String?, branch: String? = nil, repo: String? = nil, path: String? = nil,
        commit: String? = nil
    ) -> PsyNeuLinkInstallClient.Current {
        PsyNeuLinkInstallClient.Current(
            version: "1.0", source: source, branch: branch, repo: repo, path: path,
            commit: commit)
    }

    func testPypiRefreshesFromPyPI() {
        let choice = Updater.refreshArguments(for: current(source: "pypi"), fallback: ["x"])
        XCTAssertEqual(choice.pipArgs, ["psyneulink"])
        XCTAssertFalse(choice.forceReinstall)
    }

    func testGithubRefreshesTheRequestedRef() {
        // The ref, not the resolved commit — otherwise a branch install pins
        // itself the first time it updates and never moves again (#116).
        let choice = Updater.refreshArguments(
            for: current(source: "github", branch: "devel", repo: "PrincetonUniversity/PsyNeuLink"),
            fallback: ["x"])
        XCTAssertEqual(choice.pipArgs, ["git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"])
        XCTAssertTrue(choice.forceReinstall)
    }

    func testAnEditableCheckoutIsNotReplacedByAClone() {
        // The backend calls this "github" because the clone has a GitHub
        // origin, and that is the right thing to *display*. Acting on it would
        // reinstall from the remote and throw away the user's working copy.
        let choice = Updater.refreshArguments(
            for: current(
                source: "github", branch: "jonhanke-dev",
                repo: "PrincetonUniversity/PsyNeuLink",
                path: "/Users/someone/PsyNeuLink"),
            fallback: ["x"])
        XCTAssertTrue(choice.pipArgs == ["-e", "/Users/someone/PsyNeuLink"])
    }

    func testADetachedHeadCheckoutStillRefreshesInPlace() {
        // git symbolic-ref gives nothing on a detached HEAD, so branch is nil.
        // The path is still the right answer.
        let choice = Updater.refreshArguments(
            for: current(source: "github", branch: nil, repo: "o/r", path: "/tmp/PsyNeuLink"),
            fallback: ["x"])
        XCTAssertTrue(choice.pipArgs == ["-e", "/tmp/PsyNeuLink"])
    }

    func testAGithubInstallWithNoRepoUsesTheDefault() {
        let choice = Updater.refreshArguments(
            for: current(source: "github", branch: "devel", repo: nil), fallback: ["x"])
        XCTAssertEqual(choice.pipArgs.first?.contains(PsyNeuLinkSource.defaultRepo), true)
    }

    func testAnUnreachableBackendFallsBackToWhatTheAppRemembers() {
        // Not ideal, but refusing to update at all would be worse, and the
        // stored preference is usually right.
        let choice = Updater.refreshArguments(for: nil, fallback: ["psyneulink"])
        XCTAssertEqual(choice.pipArgs, ["psyneulink"])
    }

    func testAnUnrecognisedSourceFallsBackRatherThanGuessing() {
        let choice = Updater.refreshArguments(
            for: current(source: "something-new"), fallback: ["psyneulink"])
        XCTAssertEqual(choice.pipArgs, ["psyneulink"])
    }
}
