import XCTest

@testable import PsyNeuView

/// Setup failed offline although the app's cache held everything it needed
/// (#57): the Mac had woken before its Wi-Fi, uv and then pip hit a DNS
/// error, and the window said "Check the logs".
final class OfflineSetupTests: XCTestCase {

    /// The lines uv printed on 2026-11-17.
    private let reported = """
        error: Failed to build `psyneulink @ file:///Users/x/.psyneuview/sources/PsyNeuLink-PrincetonUniversity`
          Caused by: Failed to resolve requirements from `build-system.requires`
          Caused by: Failed to fetch: `https://pypi.org/simple/setuptools/`
          Caused by: error sending request for url (https://pypi.org/simple/setuptools/)
          Caused by: client error (Connect)
          Caused by: dns error
          Caused by: failed to lookup address information: nodename nor servname provided, or not known
        """

    func testTheReportedFailureIsTheNetwork() {
        XCTAssertTrue(PsyNeuLinkInstall.isNetworkFailure(reported))
    }

    /// A real build or resolution error must still go to pip, not offline.
    func testOtherFailuresAreNot() {
        XCTAssertFalse(PsyNeuLinkInstall.isNetworkFailure(
            "error: No solution found when resolving dependencies: numpy>=3 is not available"))
        XCTAssertFalse(PsyNeuLinkInstall.isNetworkFailure(
            "error: Failed to build `psyneulink`: setup.py returned non-zero exit status 1"))
        XCTAssertFalse(PsyNeuLinkInstall.isNetworkFailure(""))
    }

    func testOfflineGoesAfterThePipSubcommand() {
        XCTAssertEqual(PsyNeuLinkInstall.offline(["pip", "install", "--link-mode=clone", "-e", "/src"]),
                       ["pip", "install", "--offline", "--link-mode=clone", "-e", "/src"])
    }

    func testOfflineGoesAfterSync() {
        XCTAssertEqual(PsyNeuLinkInstall.offline(PsyNeuLinkInstall.lockSyncArguments()).prefix(2),
                       ["sync", "--offline"])
    }

    func testOfflineIsAddedOnce() {
        let once = PsyNeuLinkInstall.offline(["pip", "install", "x"])
        XCTAssertEqual(PsyNeuLinkInstall.offline(once), once)
    }

    /// Every install command the app builds can run offline: the PsyNeuLink
    /// installs in every position, and the lock sync.
    func testEveryUvCommandTakesOffline() {
        for position in [PsyNeuLinkInstall.Position.first, .override, .upgrade] {
            let command = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: ["psyneulink"], position: position)
            XCTAssertEqual(PsyNeuLinkInstall.offline(command.arguments)[2], "--offline")
        }
    }

    /// The window says what's wrong and what to do, in plain words.
    func testTheMessageSaysWhatToDo() {
        let message = PsyNeuLinkInstall.offlineMessage
        XCTAssertTrue(message.contains("internet"))
        XCTAssertTrue(message.contains("Try Again"))
        XCTAssertFalse(message.lowercased().contains("dns"))
    }
}
