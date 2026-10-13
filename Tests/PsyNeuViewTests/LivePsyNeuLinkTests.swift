import XCTest
@testable import PsyNeuView

/// Issue #9: moves and repairs keep the PsyNeuLink that is actually installed.
final class LivePsyNeuLinkTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testEditableCheckoutIsKeptAsDashE() throws {
        let live = try XCTUnwrap(LivePsyNeuLink.parse(
            directURL: json(#"{"url": "file:///Users/someone/PyCharmProjects/PsyNeuLink", "dir_info": {"editable": true}}"#),
            version: "0.18.0.0+659.gb806e593d0.dirty"))
        XCTAssertEqual(live.source, .local)
        XCTAssertEqual(live.pipArgs, ["-e", "/Users/someone/PyCharmProjects/PsyNeuLink"])
    }

    func testEditablePathWithSpacesIsDecoded() throws {
        let live = try XCTUnwrap(LivePsyNeuLink.parse(
            directURL: json(#"{"url": "file:///Users/someone/My%20Code/PsyNeuLink", "dir_info": {"editable": true}}"#),
            version: nil))
        XCTAssertEqual(live.localPath, "/Users/someone/My Code/PsyNeuLink")
    }

    func testGitInstallKeepsRepoAndRequestedRef() throws {
        let live = try XCTUnwrap(LivePsyNeuLink.parse(
            directURL: json(#"{"url": "https://github.com/SomeFork/PsyNeuLink.git", "vcs_info": {"vcs": "git", "requested_revision": "my-branch", "commit_id": "abc"}}"#),
            version: "0.21.0.0"))
        XCTAssertEqual(live.source, .github)
        XCTAssertEqual(live.pipArgs, ["git+https://github.com/SomeFork/PsyNeuLink.git@my-branch"])
    }

    func testPrincetonRepoIsStoredAsTheDefault() throws {
        let live = try XCTUnwrap(LivePsyNeuLink.parse(
            directURL: json(#"{"url": "https://github.com/PrincetonUniversity/PsyNeuLink.git", "vcs_info": {"vcs": "git", "requested_revision": "devel"}}"#),
            version: nil))
        XCTAssertEqual(live.repo, "")
        XCTAssertEqual(live.pipArgs, ["git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"])
    }

    func testPyPIKeepsItsExactVersion() throws {
        let live = try XCTUnwrap(LivePsyNeuLink.parse(directURL: nil, version: "0.20.2.0"))
        XCTAssertEqual(live.source, .pypi)
        XCTAssertEqual(live.pipArgs, ["psyneulink==0.20.2.0"])
    }

    func testUnreadableRecordFallsBack() {
        XCTAssertNil(LivePsyNeuLink.parse(directURL: json("not json"), version: "1"))
        XCTAssertNil(LivePsyNeuLink.parse(directURL: nil, version: nil))
        XCTAssertNil(LivePsyNeuLink.parse(
            directURL: json(#"{"url": "https://gitlab.com/x/PsyNeuLink.git", "vcs_info": {"vcs": "git"}}"#),
            version: "1"))
    }

    func testMetadataVersion() {
        XCTAssertEqual(LivePsyNeuLink.version(fromMetadata: "Metadata-Version: 2.1\nName: psyneulink\nVersion: 0.21.0.0\n"), "0.21.0.0")
    }

    /// The user's case: an environment built from their checkout, being left
    /// for a newer included PsyNeuView.
    func testReadsAnEditableInstallFromAnEnvironmentOnDisk() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("pnl-live-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: repo) }
        let info = repo.appendingPathComponent(
            "backend/.venv/lib/python3.14/site-packages/psyneulink-0.18.0.0+659.dist-info")
        try fm.createDirectory(at: info, withIntermediateDirectories: true)
        try json(#"{"url": "file:///Users/someone/PsyNeuLink", "dir_info": {"editable": true}}"#)
            .write(to: info.appendingPathComponent("direct_url.json"))
        try "Name: psyneulink\nVersion: 0.18.0.0+659\n"
            .write(to: info.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)

        let live = try XCTUnwrap(LivePsyNeuLink.read(environmentOf: repo))
        XCTAssertEqual(live.pipArgs, ["-e", "/Users/someone/PsyNeuLink"])
        XCTAssertEqual(live.version, "0.18.0.0+659")
        XCTAssertNil(LivePsyNeuLink.read(environmentOf: repo.appendingPathComponent("missing")))
    }

    /// The record follows the live install, and says what changed only once.
    func testReconcileUpdatesTheRecordToTheLiveInstall() {
        let prefs = Preferences()
        let saved = (prefs.pnlSource, prefs.pnlBranch, prefs.pnlRepo, prefs.pnlLocalPath)
        defer {
            prefs.pnlSource = saved.0; prefs.pnlBranch = saved.1
            prefs.pnlRepo = saved.2; prefs.pnlLocalPath = saved.3
        }
        prefs.pnlSource = .github; prefs.pnlBranch = "devel"; prefs.pnlRepo = ""; prefs.pnlLocalPath = ""

        let live = LivePsyNeuLink(source: .local, localPath: "/Users/someone/PsyNeuLink")
        XCTAssertNotNil(LivePsyNeuLink.reconcile(prefs, with: live))
        XCTAssertEqual(prefs.pnlSource, .local)
        XCTAssertEqual(prefs.pnlPipArgs, ["-e", "/Users/someone/PsyNeuLink"])
        XCTAssertNil(LivePsyNeuLink.reconcile(prefs, with: live), "already in step: nothing to say")
    }
}

