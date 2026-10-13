import WebKit
import XCTest
@testable import PsyNeuView

/// The window's web cache is cleared when the app or PsyNeuView changes (#1).
final class WebCacheTests: XCTestCase {

    func testNothingOnRecordClears() {
        // The first launch of a version with this check: a page that is
        // already stale gets fixed by installing the update.
        XCTAssertTrue(WebCache.shouldClear(last: nil, current: "app=0.6.0 (1);psyneuview=0.6.0;head=-"))
        XCTAssertTrue(WebCache.shouldClear(last: "", current: "app=0.6.0 (1);psyneuview=0.6.0;head=-"))
    }

    func testSameStampKeepsTheCache() {
        let s = WebCache.stamp(appVersion: "0.6.0 (1)", psyneuviewVersion: "0.6.0", checkoutHead: nil)
        XCTAssertFalse(WebCache.shouldClear(last: s, current: s))
    }

    func testAnAppUpdateClears() {
        let old = WebCache.stamp(appVersion: "0.5.22 (1)", psyneuviewVersion: "0.5.16", checkoutHead: nil)
        let new = WebCache.stamp(appVersion: "0.6.0 (1)", psyneuviewVersion: "0.5.16", checkoutHead: nil)
        XCTAssertTrue(WebCache.shouldClear(last: old, current: new))
    }

    func testANewPsyNeuViewClears() {
        let old = WebCache.stamp(appVersion: "0.6.0 (1)", psyneuviewVersion: "0.5.16", checkoutHead: nil)
        let new = WebCache.stamp(appVersion: "0.6.0 (1)", psyneuviewVersion: "0.6.0", checkoutHead: nil)
        XCTAssertTrue(WebCache.shouldClear(last: old, current: new))
    }

    func testACheckoutOnANewCommitClears() {
        let old = WebCache.stamp(appVersion: "0.6.0 (1)", psyneuviewVersion: nil, checkoutHead: "aaa")
        let new = WebCache.stamp(appVersion: "0.6.0 (1)", psyneuviewVersion: nil, checkoutHead: "bbb")
        XCTAssertTrue(WebCache.shouldClear(last: old, current: new))
    }

    func testOnlyTheHTTPCachesAreCleared() {
        // Local storage holds the page's preferences; it must survive.
        XCTAssertEqual(WebCache.clearedTypes, [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
        XCTAssertFalse(WebCache.clearedTypes.contains(WKWebsiteDataTypeLocalStorage))
    }

    func testStampReadsTheBundledVersionAndTheAppVersion() throws {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        try "version=0.6.0\n".write(to: tree.appendingPathComponent("BUNDLED_VERSION"), atomically: true, encoding: .utf8)
        let stamp = WebCache.currentStamp(
            repoPath: tree, info: ["CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "7"])
        XCTAssertEqual(stamp, "app=0.6.0 (7);psyneuview=0.6.0;head=-")
    }

    func testHeadCommitFollowsALooseAndAPackedRef() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "ref: refs/heads/devel\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "# pack-refs\nabc123 refs/heads/devel\n".write(
            to: git.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WebCache.headCommit(of: repo), "abc123")
        try "def456\n".write(to: git.appendingPathComponent("refs/heads/devel"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WebCache.headCommit(of: repo), "def456")
        XCTAssertNil(WebCache.headCommit(of: repo.appendingPathComponent("nope")))
    }
}
