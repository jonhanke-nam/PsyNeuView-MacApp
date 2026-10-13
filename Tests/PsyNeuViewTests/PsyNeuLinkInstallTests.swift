import XCTest
@testable import PsyNeuView

// Installing PsyNeuLink with the bundled uv, pip behind it (#224).
// XCTest (not Swift Testing) so it runs on the CI toolchain's Xcode.

final class PsyNeuLinkInstallTests: XCTestCase {
    let devel = ["git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"]
    let fork = ["git+https://github.com/jonhanke-nam/PsyNeuLink.git@jonhanke-dev"]
    let local = ["-e", "/Users/someone/PsyNeuLink"]

    // MARK: What the arguments name

    func testTheThreeSourceKindsAreRecognised() {
        XCTAssertEqual(PsyNeuLinkInstall.kind(of: ["psyneulink"]), .pypi)
        XCTAssertEqual(PsyNeuLinkInstall.kind(of: devel), .git(url: devel[0]))
        XCTAssertEqual(PsyNeuLinkInstall.kind(of: fork), .git(url: fork[0]))
        XCTAssertEqual(PsyNeuLinkInstall.kind(of: local), .local(path: "/Users/someone/PsyNeuLink"))
    }

    func testShapesTheAppNeverMakesAreNotASource() {
        XCTAssertNil(PsyNeuLinkInstall.kind(of: []))
        XCTAssertNil(PsyNeuLinkInstall.kind(of: ["-e", ""]))
        XCTAssertNil(PsyNeuLinkInstall.kind(of: ["numpy"]))
        XCTAssertNil(PsyNeuLinkInstall.kind(of: ["-e", "/a", "/b"]))
    }

    // MARK: The uv command, per source kind

    func testAFreshInstallFromGitHubIsOneUvRunThatBringsItsDependencies() {
        let c = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: devel, position: .first)
        XCTAssertEqual(c.tool, .uv)
        XCTAssertEqual(c.arguments, ["pip", "install", "--link-mode=clone"] + devel)
        XCTAssertFalse(c.arguments.contains("--no-deps"), "running first, PsyNeuLink must bring torch and the rest")
        XCTAssertEqual(c.label, "PsyNeuLink (\(devel[0])) with uv")
        XCTAssertEqual(c.timelineID, "psyneulink")
    }

    func testAFreshInstallFromPyPIAsksForTheRelease() {
        let c = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: ["psyneulink"], position: .first)
        XCTAssertEqual(c.arguments, ["pip", "install", "--link-mode=clone", "psyneulink"])
    }

    func testAFreshInstallFromACheckoutIsEditable() {
        let c = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: local, position: .first)
        XCTAssertEqual(c.arguments, ["pip", "install", "--link-mode=clone", "-e", "/Users/someone/PsyNeuLink"])
    }

    func testTheOverrideReplacesOnlyPsyNeuLinkAndAsksTheBranchForItsTip() {
        let c = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: devel, position: .override)
        XCTAssertEqual(c.arguments, [
            "pip", "install", "--link-mode=clone", "--upgrade", "--no-deps",
            "--reinstall-package", "psyneulink", "--refresh-package", "psyneulink",
        ] + devel)
        XCTAssertFalse(c.arguments.contains("--reinstall"), "a bare --reinstall would rewrite the whole tree")
        XCTAssertEqual(c.label, "PsyNeuLink override (\(devel[0])) with uv")
        XCTAssertEqual(c.timelineID, "psyneulinkOverride")
    }

    func testAnUpgradeIsAPlainUpgrade() {
        let c = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: ["psyneulink"], position: .upgrade)
        XCTAssertEqual(c.arguments, ["pip", "install", "--link-mode=clone", "--upgrade", "psyneulink"])
        XCTAssertEqual(c.timelineID, "psyneulinkUpgrade")
    }

    func testEveryUvRunClonesFromTheCacheRatherThanHardLinking() {
        // A hard link would make site-packages and the cache one inode, and
        // fails across volumes; a clone is copy-on-write and falls back to a
        // copy on its own.
        for position in [PsyNeuLinkInstall.Position.first, .override, .upgrade] {
            for args in [["psyneulink"], devel, local] {
                let c = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: args, position: position)
                XCTAssertTrue(c.arguments.contains("--link-mode=clone"), "\(position) \(args)")
                XCTAssertFalse(c.arguments.contains { $0.contains("hardlink") })
            }
        }
    }

    // MARK: The pip command is what it was

    func testPipKeepsItsFlags() {
        XCTAssertEqual(
            PsyNeuLinkInstall.command(tool: .pip, pnlPipArgs: devel, position: .first).arguments,
            ["install"] + devel)
        XCTAssertEqual(
            PsyNeuLinkInstall.command(tool: .pip, pnlPipArgs: devel, position: .override).arguments,
            ["install", "--upgrade", "--force-reinstall", "--no-deps"] + devel)
        XCTAssertEqual(
            PsyNeuLinkInstall.command(tool: .pip, pnlPipArgs: ["psyneulink"], position: .upgrade).arguments,
            ["install", "--upgrade", "psyneulink"])
        XCTAssertEqual(
            PsyNeuLinkInstall.command(tool: .pip, pnlPipArgs: devel, position: .first).label,
            "PsyNeuLink (\(devel[0])) with pip")
    }

    func testTheSourceArgumentsAreTheSameForBothTools() {
        for args in [["psyneulink"], devel, fork, local] {
            let uv = PsyNeuLinkInstall.command(tool: .uv, pnlPipArgs: args, position: .first)
            let pip = PsyNeuLinkInstall.command(tool: .pip, pnlPipArgs: args, position: .first)
            XCTAssertEqual(Array(uv.arguments.suffix(args.count)), args)
            XCTAssertEqual(Array(pip.arguments.suffix(args.count)), args)
        }
    }

    // MARK: Falling back

    func testSuccessIsSuccessWhicheverToolRan() {
        XCTAssertEqual(PsyNeuLinkInstall.outcome(exitCode: 0, tool: .uv, pipAvailable: true), .installed)
        XCTAssertEqual(PsyNeuLinkInstall.outcome(exitCode: 0, tool: .pip, pipAvailable: true), .installed)
        XCTAssertEqual(PsyNeuLinkInstall.outcome(exitCode: 0, tool: .uv, pipAvailable: false), .installed)
    }

    func testUvFailingHandsTheJobToPipWithTheReason() {
        XCTAssertEqual(
            PsyNeuLinkInstall.outcome(exitCode: 2, tool: .uv, pipAvailable: true),
            .retryWithPip(reason: "uv exited with code 2"))
        // A uv that never launched (Shell reports -1) is a failure like any other.
        XCTAssertEqual(
            PsyNeuLinkInstall.outcome(exitCode: -1, tool: .uv, pipAvailable: true),
            .retryWithPip(reason: "uv exited with code -1"))
    }

    func testUvFailingWithNoPipIsTheEnd() {
        XCTAssertEqual(
            PsyNeuLinkInstall.outcome(exitCode: 1, tool: .uv, pipAvailable: false),
            .failed(reason: "uv exited with code 1"))
    }

    func testPipFailingIsTheEnd() {
        XCTAssertEqual(
            PsyNeuLinkInstall.outcome(exitCode: 1, tool: .pip, pipAvailable: true),
            .failed(reason: "pip exited with code 1"))
    }

    // MARK: The cache

    func testTheCacheLivesWithTheAppsData() {
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support/PsyNeuView")
        XCTAssertEqual(
            PsyNeuLinkInstall.cacheDirectory(supportDirectory: support).path,
            "/Users/someone/Library/Application Support/PsyNeuView/uv-cache")
        let env = PsyNeuLinkInstall.environment(base: ["PATH": "/usr/bin"], supportDirectory: support)
        XCTAssertEqual(env["UV_CACHE_DIR"], "/Users/someone/Library/Application Support/PsyNeuView/uv-cache")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testACacheSetByWhoeverLaunchedTheAppWins() {
        // The first-launch profile and the release checks point uv at an
        // empty cache to measure a cold install.
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support/PsyNeuView")
        let env = PsyNeuLinkInstall.environment(
            base: ["UV_CACHE_DIR": "/tmp/profile/uv-cache"], supportDirectory: support)
        XCTAssertEqual(env["UV_CACHE_DIR"], "/tmp/profile/uv-cache")
        // An empty value is no value.
        let blank = PsyNeuLinkInstall.environment(base: ["UV_CACHE_DIR": ""], supportDirectory: support)
        XCTAssertEqual(blank["UV_CACHE_DIR"], "/Users/someone/Library/Application Support/PsyNeuView/uv-cache")
    }
}
