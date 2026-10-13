import XCTest
@testable import PsyNeuView

final class SystemSettingsLinksTests: XCTestCase {
    func testSpokenContentLinkOpensInSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
        XCTAssertTrue(SystemSettingsLinks.opensInSystemSettings(url))
    }

    func testOtherLinksStayInTheWebView() {
        for s in ["http://127.0.0.1:8000/", "https://github.com/jonhanke-nam/PsyNeuView", "file:///tmp/x.py", "about:blank"] {
            XCTAssertFalse(SystemSettingsLinks.opensInSystemSettings(URL(string: s)), s)
        }
        XCTAssertFalse(SystemSettingsLinks.opensInSystemSettings(nil))
    }
}
