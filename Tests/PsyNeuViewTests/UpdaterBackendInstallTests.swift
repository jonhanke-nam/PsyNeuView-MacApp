import XCTest

@testable import PsyNeuView

/// A checkout's refresh reinstalled the backend with pip alone, while setup
/// used the bundled uv (#53): a pull that moved a dependency was the slow path.
final class UpdaterBackendInstallTests: XCTestCase {

    func testUvGoesFirstThenPip() {
        let attempts = Updater.backendInstallAttempts(
            uvPath: "/b/uv", venvPip: "/v/bin/pip", pipExists: true, extraArguments: [])
        XCTAssertEqual(attempts.map(\.tool), [.uv, .pip])
        XCTAssertEqual(attempts[0].executable, "/b/uv")
        XCTAssertEqual(attempts[0].arguments,
                       ["pip", "install", "--link-mode=\(PsyNeuLinkInstall.linkMode)", "-e", "."])
        XCTAssertEqual(attempts[1].arguments, ["install", "-e", "."])
    }

    /// The metadata refresh keeps its flags on both tools.
    func testExtraArgumentsReachBothTools() {
        let attempts = Updater.backendInstallAttempts(
            uvPath: "/b/uv", venvPip: "/v/bin/pip", pipExists: true,
            extraArguments: ["--no-deps", "-q"])
        XCTAssertEqual(attempts[0].arguments.suffix(2), ["--no-deps", "-q"])
        XCTAssertEqual(attempts[1].arguments.suffix(2), ["--no-deps", "-q"])
    }

    func testWithoutUvOnlyPip() {
        let attempts = Updater.backendInstallAttempts(
            uvPath: nil, venvPip: "/v/bin/pip", pipExists: true, extraArguments: [])
        XCTAssertEqual(attempts.map(\.tool), [.pip])
    }

    /// uv needs no pip in the environment; with neither, nothing runs.
    func testUvAloneAndNeither() {
        XCTAssertEqual(Updater.backendInstallAttempts(
            uvPath: "/b/uv", venvPip: "/v/bin/pip", pipExists: false, extraArguments: []).map(\.tool),
            [.uv])
        XCTAssertTrue(Updater.backendInstallAttempts(
            uvPath: nil, venvPip: "/v/bin/pip", pipExists: false, extraArguments: []).isEmpty)
    }
}
