import Foundation
import XCTest

@testable import PsyNeuView

/// The AI assistant's page secret (PsyNeuView#381): made per launch, handed
/// to the backend in a file only this user can read, and to the page with a
/// user script on the backend's origin only.
final class PageSecretTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-secret-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testASecretIsLongRandomAndURLSafe() {
        let a = PageSecret.make()
        let b = PageSecret.make()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 43)  // 32 bytes, base64 without padding
        // At least the backend's minimum, and safe in a URL fragment and a header.
        XCTAssertGreaterThanOrEqual(a.count, 32)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(a.unicodeScalars.allSatisfy { allowed.contains($0) }, a)
    }

    func testTheLaunchSecretStaysTheSame() {
        XCTAssertEqual(PageSecret.current, PageSecret.current)
    }

    func testTheFileHoldsOnlyTheSecretAndOnlyThisUserCanReadIt() throws {
        let file = try PageSecret.writeFile("s3cret-value", in: dir)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "s3cret-value")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)
        // A new name each start.
        let second = try PageSecret.writeFile("s3cret-value", in: dir)
        XCTAssertNotEqual(file, second)
    }

    func testTheBackendGetsAFileNotTheValue() throws {
        let vars = try PageSecret.backendVariables(secret: "abc", reload: false, directory: dir)
        XCTAssertNil(vars[PageSecret.valueVariable])
        let path = try XCTUnwrap(vars[PageSecret.fileVariable])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "abc")
    }

    func testWithReloadTheValueGoesInTheEnvironment() throws {
        let vars = try PageSecret.backendVariables(secret: "abc", reload: true, directory: dir)
        XCTAssertEqual(vars, [PageSecret.valueVariable: "abc"])
    }

    func testTheEnvironmentCarriesOnlyThisLaunchsVariables() {
        let inherited = [PageSecret.valueVariable: "from-a-shell", PageSecret.fileVariable: "/tmp/old"]
        let none = ProcessManager.backendEnvironment(base: inherited, repoPath: URL(fileURLWithPath: "/tmp/t"))
        XCTAssertNil(none[PageSecret.valueVariable])
        XCTAssertNil(none[PageSecret.fileVariable])
        let given = ProcessManager.backendEnvironment(
            base: inherited, repoPath: URL(fileURLWithPath: "/tmp/t"),
            pageSecretVariables: [PageSecret.fileVariable: "/tmp/new"])
        XCTAssertEqual(given[PageSecret.fileVariable], "/tmp/new")
        XCTAssertNil(given[PageSecret.valueVariable])
    }

    func testOriginIsSpelledAsTheBrowserSpellsIt() {
        XCTAssertEqual(PageSecret.origin(of: URL(string: "http://127.0.0.1:8123/")!), "http://127.0.0.1:8123")
        XCTAssertEqual(PageSecret.origin(of: URL(string: "http://localhost:8123/x?y#z")!), "http://localhost:8123")
        XCTAssertEqual(PageSecret.origin(of: URL(string: "http://127.0.0.1/")!), "http://127.0.0.1")
        XCTAssertEqual(PageSecret.origin(of: URL(string: "http://[::1]:8000/")!), "http://[::1]:8000")
        XCTAssertNil(PageSecret.origin(of: URL(fileURLWithPath: "/tmp/index.html")))
    }

    func testTheUserScriptWritesTheSecretOnTheBackendsOriginOnly() {
        let script = PageSecret.userScript(secret: "abc_DEF-1", origin: "http://127.0.0.1:8123")
        XCTAssertTrue(script.contains("window.location.origin !== \"http://127.0.0.1:8123\""))
        XCTAssertTrue(script.contains("sessionStorage.setItem(\"psyneuview.pageSecret\", \"abc_DEF-1\")"))
        // The key is the page's own (frontend/src/utils/pageSecret.ts).
        XCTAssertEqual(PageSecret.storageKey, "psyneuview.pageSecret")
    }

    func testQuotesInTheScriptCantBreakOut() {
        let script = PageSecret.userScript(secret: "a\"); alert(1); (\"", origin: "http://127.0.0.1:1")
        XCTAssertTrue(script.contains("\"a\\\"); alert(1); (\\\"\""), script)
    }
}
