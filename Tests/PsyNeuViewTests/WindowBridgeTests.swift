import XCTest
@testable import PsyNeuView

final class WindowBridgeTests: XCTestCase {
    private let page = URL(string: "http://127.0.0.1:65200/")

    private func allowed(_ url: Any, isMainFrame: Bool = true, page: URL?) -> URL? {
        WindowBridge.allowedURL(body: ["url": url], isMainFrame: isMainFrame, page: page)
    }

    func testOpensAnAddressOnThePagesOwnOrigin() {
        // Each address the page asks for (PsyNeuView#174).
        for address in [
            "http://127.0.0.1:65200/?tour=ddm", "http://127.0.0.1:65200/?openModel=Hopfield%20Network",
            "http://127.0.0.1:65200/?newModel=1", "http://127.0.0.1:65200/?open=0123abcd",
        ] {
            XCTAssertEqual(allowed(address, page: page)?.absoluteString, address)
        }
    }

    func testRefusesAnyOtherOrigin() {
        for other in [
            "https://example.com/", "http://127.0.0.1:65201/", "http://localhost:65200/",
            "https://127.0.0.1:65200/", "file:///etc/hosts",
            "http://127.0.0.1:65200@example.com/",
        ] {
            XCTAssertNil(allowed(other, page: page), other)
        }
    }

    func testRefusesAFrameOrAnUnknownPage() {
        XCTAssertNil(allowed("http://127.0.0.1:65200/", isMainFrame: false, page: page))
        XCTAssertNil(allowed("http://127.0.0.1:65200/", page: nil))
    }

    func testRefusesAMalformedMessage() {
        XCTAssertNil(allowed(42, page: page))
        XCTAssertNil(WindowBridge.allowedURL(body: "http://127.0.0.1:65200/", isMainFrame: true, page: page))
    }
}
