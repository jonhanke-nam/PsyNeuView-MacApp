import Foundation
import XCTest
@testable import PsyNeuView

/// The `pnvFile` bridge's `reveal` op (jonhanke-nam/PsyNeuView-archive#1295), over a
/// stubbed existence check — no Finder, no web view.
final class FileBridgeTests: XCTestCase {

    private let home = NSHomeDirectory()

    private func reply(_ outcome: FileBridge.RevealOutcome) -> [String: Any]? {
        if case .success(let value) = outcome.reply { return value }
        return nil
    }

    private func failure(_ outcome: FileBridge.RevealOutcome) -> String? {
        if case .failure(let f) = outcome.reply { return f.message }
        return nil
    }

    // MARK: Success

    func testExistingFileIsRevealedAndReplyIsRevealedTrue() throws {
        let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": "/tmp/model.yaml"]) { _ in true }
        XCTAssertEqual(try XCTUnwrap(reply(outcome))["revealed"] as? Bool, true)
        XCTAssertEqual(outcome.reveal?.path, "/tmp/model.yaml")
        XCTAssertTrue(try XCTUnwrap(outcome.reveal).isFileURL)
    }

    func testExistingFolderIsRevealedTheSameWay() {
        let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": "/tmp/models/"]) { _ in true }
        XCTAssertNotNil(reply(outcome))
        // Standardized: the trailing slash goes; Finder selects the folder in its parent.
        XCTAssertEqual(outcome.reveal?.path, "/tmp/models")
    }

    func testTildeIsTheHomeFolder() {
        var asked: [String] = []
        let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": "~/.psyneuview/sources"]) {
            asked.append($0)
            return true
        }
        XCTAssertEqual(asked, [home + "/.psyneuview/sources"])
        XCTAssertEqual(outcome.reveal?.path, home + "/.psyneuview/sources")
        XCTAssertNotNil(reply(outcome))
    }

    func testPathIsNormalizedBeforeTheCheck() {
        var asked: [String] = []
        _ = FileBridge.handleReveal(body: ["op": "reveal", "path": "  /Users//someone/./models/../runs/  "]) {
            asked.append($0)
            return true
        }
        XCTAssertEqual(asked, ["/Users/someone/runs"])
    }

    func testExtraFieldsAreIgnored() {
        let outcome = FileBridge.handleReveal(
            body: ["op": "reveal", "path": "/tmp/x", "directories": true, "message": "hi"]) { _ in true }
        XCTAssertNotNil(reply(outcome))
    }

    // MARK: Refusals

    func testMissingItemIsRefusedWithTheAbbreviatedPath() {
        let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": "~/Desktop/gone.yaml"]) { _ in false }
        XCTAssertEqual(failure(outcome), "There's no folder or file at ~/Desktop/gone.yaml.")
        XCTAssertNil(outcome.reveal)
    }

    func testMissingItemOutsideHomeIsShownInFull() {
        let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": "/opt/nowhere"]) { _ in false }
        XCTAssertEqual(failure(outcome), "There's no folder or file at /opt/nowhere.")
    }

    func testNoPathIsRefusedWithoutCheckingDisk() {
        var checked = false
        let outcome = FileBridge.handleReveal(body: ["op": "reveal"]) { _ in
            checked = true
            return true
        }
        XCTAssertEqual(failure(outcome), "pnvFile: 'reveal' needs a 'path'")
        XCTAssertFalse(checked)
        XCTAssertNil(outcome.reveal)
    }

    func testEmptyOrBlankPathIsRefused() {
        for path in ["", "   ", "\n"] {
            let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": path]) { _ in true }
            XCTAssertEqual(failure(outcome), "pnvFile: 'reveal' needs a 'path'", "path \(path.debugDescription)")
        }
    }

    func testNonStringPathIsRefused() {
        let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": 42]) { _ in true }
        XCTAssertEqual(failure(outcome), "pnvFile: 'reveal' needs a 'path'")
    }

    func testRelativePathIsRefusedRatherThanLookedUpFromTheCwd() {
        var checked = false
        let outcome = FileBridge.handleReveal(body: ["op": "reveal", "path": "models/x.yaml"]) { _ in
            checked = true
            return true
        }
        XCTAssertEqual(failure(outcome), "pnvFile: 'reveal' needs an absolute path, not 'models/x.yaml'")
        XCTAssertFalse(checked)
    }

    // MARK: Helpers the op is built on

    func testNormalizedPath() {
        XCTAssertEqual(FileBridge.normalizedPath("~"), home)
        XCTAssertEqual(FileBridge.normalizedPath("~/a/b/"), home + "/a/b")
        XCTAssertEqual(FileBridge.normalizedPath("/a/b/../c"), "/a/c")
        XCTAssertEqual(FileBridge.normalizedPath(""), "")
        XCTAssertEqual(FileBridge.normalizedPath("  "), "")
    }

    func testAbbreviatedPathUsesTildeForHome() {
        XCTAssertEqual(FileBridge.abbreviated(home + "/Desktop"), "~/Desktop")
        XCTAssertEqual(FileBridge.abbreviated("/tmp/x"), "/tmp/x")
    }

    func testHandlerNameAndReplyShapeAreTheContract() {
        XCTAssertEqual(FileBridge.handlerName, "pnvFile")
        XCTAssertEqual(FileBridge.revealedReply["revealed"] as? Bool, true)
        XCTAssertEqual(FileBridge.revealedReply.count, 1)
    }
}
