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
