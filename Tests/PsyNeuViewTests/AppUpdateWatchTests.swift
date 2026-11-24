import XCTest
@testable import PsyNeuView
import Sparkle

/// When the page is told an app update is waiting (#6).
final class AppUpdateWatchTests: XCTestCase {
    private func found(_ v: String, notes: String? = nil) -> AppUpdateWatch.Found {
        AppUpdateWatch.Found(version: v, releaseNotesURL: notes)
    }

    func testNothingFoundMeansNothingWaiting() {
        XCTAssertFalse(AppUpdateWatch.isWaiting(running: "0.5.22", found: nil))
    }

    func testANewerVersionIsWaiting() {
        XCTAssertTrue(AppUpdateWatch.isWaiting(running: "0.5.20", found: found("0.5.22")))
        XCTAssertTrue(AppUpdateWatch.isWaiting(running: "0.5.22", found: found("0.6.0")))
        XCTAssertTrue(AppUpdateWatch.isWaiting(running: "0.6.9", found: found("0.6.10")))
    }

    func testTheSameOrAnOlderVersionIsNotWaiting() {
        // After installing, the running version catches up with the finding.
        XCTAssertFalse(AppUpdateWatch.isWaiting(running: "0.6.0", found: found("0.6.0")))
        XCTAssertFalse(AppUpdateWatch.isWaiting(running: "0.6.0", found: found("0.5.22")))
    }

    func testVersionsCompareNumericallyNotAsText() {
        XCTAssertEqual(AppUpdateWatch.compare("0.6.10", "0.6.9"), .orderedDescending)
        XCTAssertEqual(AppUpdateWatch.compare("0.6", "0.6.0"), .orderedSame)
    }

    // Release candidates (v0.6.5-rc1): Sparkle must offer a candidate over
    // the release before it, and the final release over its candidate. These
    // go through Sparkle's own comparator, the one that decides what it offers.
    func testACandidateSitsBetweenThePreviousReleaseAndItsFinal() {
        XCTAssertEqual(AppUpdateWatch.compare("0.6.5-rc1", "0.6.4"), .orderedDescending)
        XCTAssertEqual(AppUpdateWatch.compare("0.6.5", "0.6.5-rc1"), .orderedDescending)
        XCTAssertEqual(AppUpdateWatch.compare("0.6.5-rc2", "0.6.5-rc1"), .orderedDescending)
        XCTAssertEqual(AppUpdateWatch.compare("0.6.5-rc10", "0.6.5-rc9"), .orderedDescending)
        XCTAssertEqual(AppUpdateWatch.compare("0.6.10-rc1", "0.6.9"), .orderedDescending)
    }

    func testSparkleSeesTheCandidateVersionWithoutTheDash() {
        // What goes in CFBundleVersion and the appcast's <sparkle:version>.
        XCTAssertEqual(AppUpdateWatch.sparkleVersion("0.6.5-rc1"), "0.6.5rc1")
        XCTAssertEqual(AppUpdateWatch.sparkleVersion("0.6.5"), "0.6.5")
        let sparkle = SUStandardVersionComparator.default
        XCTAssertEqual(sparkle.compareVersion("0.6.5rc1", toVersion: "0.6.4"), .orderedDescending)
        XCTAssertEqual(sparkle.compareVersion("0.6.5", toVersion: "0.6.5rc1"), .orderedDescending)
        // Why the dash has to go: Sparkle stops reading at it.
        XCTAssertEqual(sparkle.compareVersion("0.6.5-rc1", toVersion: "0.6.5"), .orderedSame)
    }

    func testOnlyPeopleWhoAskedLookInTheCandidatesChannel() {
        XCTAssertEqual(AppUpdateWatch.allowedChannels(receiveCandidates: false), [])
        XCTAssertEqual(AppUpdateWatch.allowedChannels(receiveCandidates: true), ["candidates"])
    }

    func testBridgeValueSaysWhenTheWaitingUpdateIsACandidate() {
        var f = found("0.6.5-rc1")
        f.isCandidate = true
        let v = AppUpdateWatch.bridgeValue(running: "0.6.4", found: f)
        XCTAssertEqual(v["candidate"] as? Bool, true)
        XCTAssertEqual(AppUpdateWatch.bridgeValue(running: "0.6.4", found: found("0.6.5"))["candidate"] as? Bool, false)
        // The final release replaces a candidate that is running.
        XCTAssertTrue(AppUpdateWatch.isWaiting(running: "0.6.5-rc1", found: found("0.6.5")))
    }

    func testBridgeValueWhenWaiting() {
        let v = AppUpdateWatch.bridgeValue(
            running: "0.5.22", found: found("0.6.0", notes: "https://example.org/notes"))
        XCTAssertEqual(v["available"] as? Bool, true)
        XCTAssertEqual(v["version"] as? String, "0.6.0")
        XCTAssertEqual(v["releaseNotesURL"] as? String, "https://example.org/notes")
    }

    func testBridgeValueWithoutNotesSendsNull() {
        let v = AppUpdateWatch.bridgeValue(running: "0.5.22", found: found("0.6.0"))
        XCTAssertTrue(v["releaseNotesURL"] is NSNull)
    }

    func testBridgeValueCarriesTheReleaseDate() {
        // #15: the feed's <pubDate>, as an ISO 8601 time in UTC.
        var f = found("0.6.0")
        f.releasedAt = Date(timeIntervalSince1970: 1_792_089_180) // 2026-10-15T18:33:00Z
        let v = AppUpdateWatch.bridgeValue(running: "0.5.22", found: f)
        XCTAssertEqual(v["releasedAt"] as? String, "2026-10-15T18:33:00Z")
    }

    func testBridgeValueWithoutADateSendsNull() {
        let v = AppUpdateWatch.bridgeValue(running: "0.5.22", found: found("0.6.0"))
        XCTAssertTrue(v["releasedAt"] is NSNull)
    }

    func testBridgeValueWhenNotWaitingSaysOnlyThat() {
        let v = AppUpdateWatch.bridgeValue(running: "0.6.0", found: found("0.6.0"))
        XCTAssertEqual(v["available"] as? Bool, false)
        XCTAssertNil(v["version"])
        XCTAssertNil(v["releasedAt"])
    }
}

/// What the app asks Sparkle at every launch (#74). Sparkle on its own waits
/// for its 4-hour interval, so a relaunch soon after a check missed a release.
final class LaunchUpdateCheckTests: XCTestCase {
    func testEveryLaunchRunsAFullBackgroundCheck() {
        XCTAssertEqual(
            AppUpdateWatch.launchCheck(updatesEnabled: true, automaticChecks: true), .background)
    }

    /// Someone who turned automatic checks off still sees a waiting update in
    /// the window, but is not sent through a download or an alert.
    func testAutomaticChecksOffOnlyAsksTheFeed() {
        XCTAssertEqual(
            AppUpdateWatch.launchCheck(updatesEnabled: true, automaticChecks: false), .informationOnly)
    }

    /// The test app has no feed: nothing is asked.
    func testTheTestAppNeverChecks() {
        XCTAssertEqual(
            AppUpdateWatch.launchCheck(updatesEnabled: false, automaticChecks: true), .none)
        XCTAssertEqual(
            AppUpdateWatch.launchCheck(updatesEnabled: false, automaticChecks: false), .none)
    }

    /// Soon enough to notice a release at once, late enough not to compete
    /// with opening the window.
    func testTheCheckRunsAFewSecondsIn() {
        XCTAssertGreaterThanOrEqual(AppUpdateWatch.launchCheckDelay, 2)
        XCTAssertLessThanOrEqual(AppUpdateWatch.launchCheckDelay, 15)
    }

    // MARK: Install updates automatically (#79)

    func testWithAutomaticInstallOffChecksOnlyAskSoThePageCanSay() {
        XCTAssertEqual(
            AppUpdateWatch.launchCheck(updatesEnabled: true, automaticChecks: true, autoInstall: false),
            .informationOnly)
        XCTAssertEqual(
            AppUpdateWatch.launchCheck(updatesEnabled: true, automaticChecks: true, autoInstall: true),
            .background)
    }

    func testChecksEveryHourWhileOpen() {
        XCTAssertEqual(AppUpdateWatch.periodicCheckInterval, 3600)
    }

    func testTheOfferIsShownOnceToAnyoneWhoHasNotSaidYes() {
        XCTAssertTrue(AppUpdateWatch.shouldOfferAutoInstall(updatesEnabled: true, autoInstall: false, asked: false))
        XCTAssertFalse(AppUpdateWatch.shouldOfferAutoInstall(updatesEnabled: true, autoInstall: false, asked: true))
        XCTAssertFalse(AppUpdateWatch.shouldOfferAutoInstall(updatesEnabled: true, autoInstall: true, asked: false))
        XCTAssertFalse(AppUpdateWatch.shouldOfferAutoInstall(updatesEnabled: false, autoInstall: false, asked: false))
    }

    func testALaunchAfterAnUpdateSaysWhatItUpdatedTo() {
        XCTAssertEqual(AppUpdateWatch.updatedTo(running: "0.6.15", lastRun: "0.6.14"), "0.6.15")
        XCTAssertEqual(AppUpdateWatch.updatedTo(running: "0.6.15", lastRun: "0.6.15-rc2"), "0.6.15")
        XCTAssertNil(AppUpdateWatch.updatedTo(running: "0.6.15", lastRun: ""), "a first run says nothing")
        XCTAssertNil(AppUpdateWatch.updatedTo(running: "0.6.15", lastRun: "0.6.15"))
        XCTAssertNil(AppUpdateWatch.updatedTo(running: "0.6.14", lastRun: "0.6.15"))
    }

    func testUpdatedToLinksToTheNotesSparkleFoundForThatVersion() {
        let v = AppUpdateWatch.justUpdatedValue(version: "0.6.15", notesVersion: "0.6.15", notesURL: "https://x/n")
        XCTAssertEqual((v as? [String: Any])?["releaseNotesURL"] as? String, "https://x/n")
        let other = AppUpdateWatch.justUpdatedValue(version: "0.6.15", notesVersion: "0.6.16", notesURL: "https://x/n")
        XCTAssertTrue((other as? [String: Any])?["releaseNotesURL"] is NSNull)
        XCTAssertTrue(AppUpdateWatch.justUpdatedValue(version: nil, notesVersion: "", notesURL: "") is NSNull)
    }

    func testBridgeValueSaysWhenTheUpdateIsReadyToInstall() {
        let found = AppUpdateWatch.Found(version: "0.6.0", releaseNotesURL: nil)
        XCTAssertEqual(AppUpdateWatch.bridgeValue(running: "0.5.22", found: found, ready: true)["readyToInstall"] as? Bool, true)
        XCTAssertEqual(AppUpdateWatch.bridgeValue(running: "0.5.22", found: found)["readyToInstall"] as? Bool, false)
    }
}
