import XCTest
@testable import PsyNeuView

// Regression coverage for the self-check's appcast reader (#44, #52).
// XCTest (not Swift Testing) so it runs on the CI toolchain's Xcode.

final class AppcastParserTests: XCTestCase {
    // A realistic two-item appcast, newest first — mirrors the live feed shape.
    private let appcast = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel>
        <title>PsyNeuView</title>
        <item>
          <title>Version 0.4.9</title>
          <sparkle:version>0.4.9</sparkle:version>
          <sparkle:shortVersionString>0.4.9</sparkle:shortVersionString>
          <enclosure url="https://github.com/jonhanke-nam/PsyNeuView-releases/releases/download/v0.4.9/PsyNeuView-0.4.9.dmg"
                     length="1480575"
                     type="application/octet-stream"
                     sparkle:edSignature="c0n1GUEMtekX3vV3vmQV2==" />
        </item>
        <item>
          <title>Version 0.4.7</title>
          <sparkle:version>0.4.7</sparkle:version>
          <enclosure url="https://github.com/jonhanke-nam/PsyNeuView-releases/releases/download/v0.4.7/PsyNeuView-0.4.7.dmg"
                     length="1234567"
                     sparkle:edSignature="oldsigoldsig==" />
        </item>
      </channel>
    </rss>
    """

    func testPicksNewestItem() {
        let latest = AppcastParser.latest(fromXML: appcast)
        XCTAssertEqual(latest?.version, "0.4.9")
        XCTAssertEqual(latest?.enclosureURL,
                       "https://github.com/jonhanke-nam/PsyNeuView-releases/releases/download/v0.4.9/PsyNeuView-0.4.9.dmg")
    }

    func testEnclosurePointsAtPublicReleasesRepo() {
        // #52: the update download must be the public releases repo, never the
        // private code repo (which Sparkle can't fetch anonymously).
        let url = AppcastParser.latest(fromXML: appcast)?.enclosureURL ?? ""
        XCTAssertTrue(url.contains("/PsyNeuView-releases/"), "enclosure should live in the public releases repo")
        XCTAssertFalse(url.contains("/PsyNeuView-MacApp/"), "enclosure must not point at the private code repo")
    }

    func testMissingVersionReturnsNil() {
        let xml = #"<item><enclosure url="https://example.com/app.dmg" /></item>"#
        XCTAssertNil(AppcastParser.latest(fromXML: xml))
    }

    func testMissingEnclosureReturnsNil() {
        let xml = "<item><sparkle:version>0.4.9</sparkle:version></item>"
        XCTAssertNil(AppcastParser.latest(fromXML: xml))
    }

    func testEmptyAndGarbageReturnNil() {
        XCTAssertNil(AppcastParser.latest(fromXML: ""))
        XCTAssertNil(AppcastParser.latest(fromXML: "not xml at all"))
        XCTAssertNil(AppcastParser.latest(fromXML: "<sparkle:version></sparkle:version>"))
    }

    func testVersionWhitespaceIsTrimmed() {
        let xml = #"<item><sparkle:version>  0.5.0  </sparkle:version><enclosure url="https://example.com/x.dmg" /></item>"#
        XCTAssertEqual(AppcastParser.latest(fromXML: xml)?.version, "0.5.0")
    }
}

/// How often the app looks for a release, and whether it installs one on its
/// own. Both are Info.plist values with no compiler behind them, so they are
/// asserted against the real file. (#167)
final class UpdateCheckConfigurationTests: XCTestCase {
    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PsyNeuViewTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        else {
            XCTFail("Resources/Info.plist is not a dictionary")
            return [:]
        }
        return plist
    }

    /// The interval and the release cadence must not be the same length.
    ///
    /// At 86400 they were, and a release published inside the window stayed
    /// invisible until the next check came due — which is how 0.5.12 went
    /// unmentioned for a morning on a machine that was running the whole time.
    func testChecksAreFrequentEnoughToNoticeADailyRelease() throws {
        let interval = try XCTUnwrap(infoPlist()["SUScheduledCheckInterval"] as? Int)
        XCTAssertLessThanOrEqual(
            interval, 6 * 60 * 60,
            "a release can go unnoticed for up to this long")
        XCTAssertGreaterThanOrEqual(
            interval, 60 * 60,
            "checking more than hourly is noise, not diligence")
    }

    func testAutomaticChecksAreOn() throws {
        XCTAssertEqual(try infoPlist()["SUEnableAutomaticChecks"] as? Bool, true)
    }

    /// Found updates download in the background and install when the app
    /// quits or relaunches (#74). Offering without installing left a relaunch
    /// on the old version. This is only the default for new installs: Sparkle
    /// keeps a choice someone already made in its update window. An update
    /// that rebuilds the Python environment does so at the next start-up, not
    /// in the middle of someone's work.
    func testUpdatesInstallOnQuitByDefault() throws {
        let plist = try infoPlist()
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertNotEqual(
            plist["SUAllowsAutomaticUpdates"] as? Bool, false,
            "automatic updates must be allowed for the default to mean anything")
    }

    /// The self-check and Sparkle both depend on these being present.
    func testTheFeedAndSigningKeyAreConfigured() throws {
        let plist = try infoPlist()
        XCTAssertFalse((plist["SUFeedURL"] as? String ?? "").isEmpty)
        XCTAssertFalse((plist["SUPublicEDKey"] as? String ?? "").isEmpty)
    }
}
