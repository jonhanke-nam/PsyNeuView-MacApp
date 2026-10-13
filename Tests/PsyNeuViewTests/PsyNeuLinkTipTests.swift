import Foundation
import XCTest

@testable import PsyNeuView

/// Don't re-clone PsyNeuLink when nothing moved (#153).
///
/// `pip install git+…@devel` cannot be served from cache — a branch name may
/// mean something different a minute later — so it re-clones the whole
/// repository on every update. Measured at ~105s of a 122s start, which is most
/// of what a slow launch is.
///
/// `git ls-remote` answers the same question in ~300ms, and the installed build
/// already carries the commit it was made from. These cover the comparison,
/// because the failure that matters is silent: answering "up to date" wrongly
/// leaves someone on stale code with nothing said.
final class PsyNeuLinkTipTests: XCTestCase {

    // Real output, from `git ls-remote …/PsyNeuLink.git devel`.
    private let lsRemote = "927cd028dd65ee83810ffee96757018e8dbddf6d\trefs/heads/devel\n"

    func testParsesTheShaFromLsRemoteOutput() {
        XCTAssertEqual(
            Updater.sha(fromLsRemote: lsRemote),
            "927cd028dd65ee83810ffee96757018e8dbddf6d"
        )
    }

    func testParsesTheFirstShaWhenSeveralRefsMatch() {
        let many = """
            927cd028dd65ee83810ffee96757018e8dbddf6d\trefs/heads/devel
            aaaabbbbccccddddeeeeffff0000111122223333\trefs/heads/devel-unsafe
            """
        XCTAssertEqual(
            Updater.sha(fromLsRemote: many),
            "927cd028dd65ee83810ffee96757018e8dbddf6d"
        )
    }

    /// A ref that does not exist produces no output at all. That must read as
    /// "cannot tell", never as "up to date".
    func testEmptyOutputYieldsNoSha() {
        XCTAssertNil(Updater.sha(fromLsRemote: ""))
        XCTAssertNil(Updater.sha(fromLsRemote: "\n"))
    }

    func testNonHexOutputYieldsNoSha() {
        XCTAssertNil(Updater.sha(fromLsRemote: "fatal: repository not found\n"))
    }

    /// The backend reports an abbreviated commit, so this is a prefix test.
    func testAbbreviatedInstalledCommitMatchesTheFullRemoteSha() {
        XCTAssertTrue(Updater.isAtRemoteTip(
            installedCommit: "927cd02",
            remoteSHA: "927cd028dd65ee83810ffee96757018e8dbddf6d"
        ))
    }

    func testAMovedRemoteIsNotUpToDate() {
        XCTAssertFalse(Updater.isAtRemoteTip(
            installedCommit: "927cd02",
            remoteSHA: "ffffffffffffffffffffffffffffffffffffffff"
        ))
    }

    /// Everything unknown must answer false: a needless reinstall costs time,
    /// a skipped one leaves stale code behind silently.
    func testUnknownsAreNotTreatedAsUpToDate() {
        let full = "927cd028dd65ee83810ffee96757018e8dbddf6d"
        XCTAssertFalse(Updater.isAtRemoteTip(installedCommit: nil, remoteSHA: full))
        XCTAssertFalse(Updater.isAtRemoteTip(installedCommit: "927cd02", remoteSHA: nil))
        XCTAssertFalse(Updater.isAtRemoteTip(installedCommit: nil, remoteSHA: nil))
        XCTAssertFalse(Updater.isAtRemoteTip(installedCommit: "", remoteSHA: full))
    }

    /// A too-short prefix would match far too much: "9" prefixes 1/16 of all
    /// commits, so it must not count as evidence.
    func testATooShortCommitIsNotEvidence() {
        let full = "927cd028dd65ee83810ffee96757018e8dbddf6d"
        XCTAssertFalse(Updater.isAtRemoteTip(installedCommit: "9", remoteSHA: full))
        XCTAssertFalse(Updater.isAtRemoteTip(installedCommit: "927cd", remoteSHA: full))
        XCTAssertTrue(Updater.isAtRemoteTip(installedCommit: "927cd02", remoteSHA: full))
    }

    /// A version string is not a commit; passing one through must not match.
    func testAVersionStringIsNotAcceptedAsACommit() {
        XCTAssertFalse(Updater.isAtRemoteTip(
            installedCommit: "0.20.2.0+17.g927cd028d",
            remoteSHA: "927cd028dd65ee83810ffee96757018e8dbddf6d"
        ))
    }
}
