import XCTest
@testable import PsyNeuView

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
        XCTAssertEqual(AppUpdateWatch.compare("0.6.0-beta", "0.6.0"), .orderedSame)
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
