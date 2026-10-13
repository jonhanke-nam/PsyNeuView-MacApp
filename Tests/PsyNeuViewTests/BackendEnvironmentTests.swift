import Foundation
import XCTest

@testable import PsyNeuView

/// The backend is told where it is running (#59).
///
/// The backend has had four deployment modes since PsyNeuView-archive#1062, chosen by
/// `PSYNEUVIEW_DEPLOYMENT_MODE`, and this app never set it. So the backend
/// believed it was a plain local install, and every mac_app branch was dead
/// code in production.
///
/// It failed silently, which is why it went unnoticed: nothing errors when the
/// variable is absent, the backend simply assumes something else. The Settings
/// panel then picked keyboard-shortcut rules for a browser while running inside
/// a WKWebView, refusing chords that would have worked.
///
/// These assert on the environment rather than on a running process, because
/// what is published here is the backend's only account of its own context.
final class BackendEnvironmentTests: XCTestCase {

    private let repo = URL(fileURLWithPath: "/tmp/psyneuview-test-tree")

    private func env(base: [String: String] = [:]) -> [String: String] {
        ProcessManager.backendEnvironment(
            base: base,
            repoPath: repo
        )
    }

    func testDeclaresTheMacAppDeploymentMode() {
        XCTAssertEqual(env()["PSYNEUVIEW_DEPLOYMENT_MODE"], "mac_app")
    }

    /// The backend accepts exactly these four; a typo silently degrades to
    /// `local`, which is the bug this fixes rather than a safe fallback.
    func testTheModeIsOneTheBackendRecognises() {
        let valid = ["local", "mac_app", "container", "hosted"]
        XCTAssertTrue(valid.contains(env()["PSYNEUVIEW_DEPLOYMENT_MODE"] ?? ""))
    }

    /// PSYNEUVIEW_MAC_APP=1 is the deprecated predecessor. Setting it instead
    /// would work today and stop working whenever the legacy path is dropped.
    func testDoesNotUseTheDeprecatedVariable() {
        XCTAssertNil(env()["PSYNEUVIEW_MAC_APP"])
    }

    /// Retired in #132: the app no longer tells the backend which PsyNeuLink it
    /// intends, because the gear icon can change it and the app's intent would
    /// then be reported as fact while something else is installed.
    func testDoesNotRepublishThePsyNeuLinkSource() {
        let e = env()
        XCTAssertNil(e["PSYNEUVIEW_PNL_SOURCE"])
        XCTAssertNil(e["PSYNEUVIEW_PNL_BRANCH"])
        XCTAssertNil(e["PSYNEUVIEW_PNL_REPO"])
    }

    func testActivatesTheVenv() {
        let e = env()
        XCTAssertEqual(e["VIRTUAL_ENV"], repo.appendingPathComponent("backend/.venv").path)
        XCTAssertTrue(
            e["PATH"]?.hasPrefix(repo.appendingPathComponent("backend/.venv/bin").path) ?? false,
            "the venv's bin must come first, or the system python wins"
        )
    }

    /// The backend owns the models folder (#212, PsyNeuView-archive#1295). While the
    /// app set `PSYNEWVIEW_MODELS_DIR` the folder was fixed from outside: no
    /// Move…, no one-time offer, no visible default under ~/Documents.
    func testDoesNotFixTheModelsFolder() {
        XCTAssertNil(env()["PSYNEWVIEW_MODELS_DIR"],
                     "the app must not set the models folder; PsyNeuView chooses it")
    }

    /// A developer who exports the variable still gets it: the app only stops
    /// setting it, it does not strip an inherited value.
    func testPassesAnInheritedModelsFolderThrough() {
        let e = env(base: ["PSYNEWVIEW_MODELS_DIR": "/Users/dev/my-models"])
        XCTAssertEqual(e["PSYNEWVIEW_MODELS_DIR"], "/Users/dev/my-models")
    }

    func testPreservesTheInheritedEnvironment() {
        let e = env(base: ["HOME": "/Users/someone", "LANG": "en_US.UTF-8"])
        XCTAssertEqual(e["HOME"], "/Users/someone")
        XCTAssertEqual(e["LANG"], "en_US.UTF-8")
    }

    func testPrependsToAnExistingPathRatherThanReplacingIt() {
        let e = env(base: ["PATH": "/usr/bin:/bin"])
        XCTAssertTrue(e["PATH"]?.hasSuffix("/usr/bin:/bin") ?? false,
                      "the inherited PATH must survive: got \(e["PATH"] ?? "nil")")
    }

    /// The backend's start-phase lines (#232) are read as they are printed;
    /// Python would otherwise hold them in a block buffer until exit.
    func testAsksPythonNotToBufferItsOutput() {
        XCTAssertEqual(env()["PYTHONUNBUFFERED"], "1")
    }
}
