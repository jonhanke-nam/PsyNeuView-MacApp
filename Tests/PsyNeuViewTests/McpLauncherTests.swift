import XCTest
import Darwin
@testable import PsyNeuView

/// The AI assistant's MCP launcher at a path that survives updates (#86,
/// PsyNeuView#201).
final class McpLauncherTests: XCTestCase {

    private var root: URL!
    private var support: URL { root.appendingPathComponent("Application Support/PsyNeuView") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("McpLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A tree with a backend Python and, unless told otherwise, the MCP command.
    private func tree(_ name: String, withMcp: Bool = true) throws -> URL {
        let tree = support.appendingPathComponent(name)
        let bin = tree.appendingPathComponent("backend/.venv/bin")
        let app = tree.appendingPathComponent("backend/app")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try Data("#!/bin/sh\n".utf8).write(to: python)
        chmod(python.path, 0o755)
        if withMcp {
            try Data().write(to: app.appendingPathComponent("mcp_server.py"))
        }
        return tree
    }

    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        XCTAssertEqual(lstat(url.path, &st), 0)
        return st.st_mode & 0o777
    }

    private func inode(_ url: URL) -> UInt64 {
        var st = stat()
        XCTAssertEqual(lstat(url.path, &st), 0)
        return UInt64(st.st_ino)
    }

    private func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: The path

    func testPathIsBinInTheSupportFolder() {
        let s = URL(fileURLWithPath: "/Users/tester/Library/Application Support/PsyNeuView")
        XCTAssertEqual(McpLauncher.path(supportDirectory: s).path,
                       "/Users/tester/Library/Application Support/PsyNeuView/bin/psyneuview-mcp")
    }

    /// The path names no version, so an update doesn't move it.
    func testPathDoesNotDependOnTheVersion() throws {
        let first = try McpLauncher.install(repoPath: try tree("psyneuview-0.6.16"), supportDirectory: support)
        let second = try McpLauncher.install(repoPath: try tree("psyneuview-0.6.17"), supportDirectory: support)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first!.path.contains("0.6.1"))
    }

    /// The test app keeps its own launcher, so it never takes over the real
    /// app's setup.
    func testTheTestAppHasItsOwnLauncher() {
        let real = McpLauncher.path(identity: .release)
        let test = McpLauncher.path(identity: .test)
        XCTAssertNotEqual(real, test)
        XCTAssertTrue(real.path.hasSuffix("/PsyNeuView/bin/psyneuview-mcp"))
        XCTAssertTrue(test.path.hasSuffix("/PsyNeuView-Test/bin/psyneuview-mcp"))
    }

    func testBackendVariables() {
        let launcher = URL(fileURLWithPath: "/x/bin/psyneuview-mcp")
        XCTAssertEqual(McpLauncher.backendVariables(launcher: launcher),
                       ["PSYNEUVIEW_MCP_LAUNCHER": "/x/bin/psyneuview-mcp"])
        XCTAssertEqual(McpLauncher.backendVariables(launcher: nil), [:])
    }

    // MARK: The script

    func testScriptRunsThisTreesBackend() throws {
        let t = try tree("psyneuview-0.6.16")
        let launcher = try XCTUnwrap(McpLauncher.install(repoPath: t, supportDirectory: support))
        let s = text(launcher)
        XCTAssertTrue(s.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(s.contains(McpLauncher.marker))
        XCTAssertTrue(s.contains("PYTHONPATH='\(t.path)/backend'"))
        XCTAssertTrue(s.contains("exec '\(t.path)/backend/.venv/bin/python' -m app.mcp_server \"$@\""))
    }

    func testPathsWithQuotesAreQuotedSafely() {
        XCTAssertEqual(McpLauncher.shellQuoted("/a b/it's"), "'/a b/it'\\''s'")
        let s = McpLauncher.script(repoPath: URL(fileURLWithPath: "/Users/o'neil/PsyNeuView"))
        XCTAssertTrue(s.contains("PYTHONPATH='/Users/o'\\''neil/PsyNeuView/backend'"))
    }

    /// The script really runs, and passes the right PYTHONPATH and arguments.
    func testScriptExecsThePythonWithItsArguments() throws {
        let t = try tree("psyneuview-0.6.16")
        let python = t.appendingPathComponent("backend/.venv/bin/python")
        try Data("#!/bin/sh\necho \"$PYTHONPATH|$*\"\n".utf8).write(to: python)
        let launcher = try XCTUnwrap(McpLauncher.install(repoPath: t, supportDirectory: support))

        let process = Process()
        process.executableURL = launcher
        process.arguments = ["--flag"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(out, "\(t.path)/backend|-m app.mcp_server --flag\n")
    }

    // MARK: Permissions

    func testFolderAndLauncherAreUserOnly() throws {
        let launcher = try XCTUnwrap(McpLauncher.install(repoPath: try tree("v1"), supportDirectory: support))
        XCTAssertEqual(mode(McpLauncher.folder(supportDirectory: support)), 0o700)
        XCTAssertEqual(mode(launcher), 0o700)
        var st = stat()
        XCTAssertEqual(lstat(launcher.path, &st), 0)
        XCTAssertEqual(st.st_uid, getuid())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher.path))
    }

    func testAnOpenFolderIsMadeUserOnly() throws {
        let bin = McpLauncher.folder(supportDirectory: support)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        chmod(bin.path, 0o777)
        try McpLauncher.install(repoPath: try tree("v1"), supportDirectory: support)
        XCTAssertEqual(mode(bin), 0o700)
    }

    func testALaunchersLooseModeIsTightened() throws {
        let launcher = try XCTUnwrap(McpLauncher.install(repoPath: try tree("v1"), supportDirectory: support))
        chmod(launcher.path, 0o777)
        try McpLauncher.install(repoPath: try tree("v1"), supportDirectory: support)
        XCTAssertEqual(mode(launcher), 0o700)
    }

    /// A link where the `bin` folder should be is refused, so the launcher is
    /// never written through it into somewhere else.
    func testRefusesALinkedBinFolder() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: McpLauncher.folder(supportDirectory: support), withDestinationURL: elsewhere)
        let t = try tree("v1")

        XCTAssertThrowsError(try McpLauncher.install(repoPath: t, supportDirectory: support)) { error in
            XCTAssertEqual(error as? McpLauncher.Failure,
                           .notAFolder(McpLauncher.folder(supportDirectory: support).path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    /// A link at the launcher's own path is replaced, not written through.
    func testALinkAtTheLauncherIsReplacedNotFollowed() throws {
        let victim = root.appendingPathComponent("victim")
        try Data("keep me".utf8).write(to: victim)
        let bin = McpLauncher.folder(supportDirectory: support)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let target = McpLauncher.path(supportDirectory: support)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)

        try McpLauncher.install(repoPath: try tree("v1"), supportDirectory: support)
        XCTAssertEqual(text(victim), "keep me")
        var st = stat()
        XCTAssertEqual(lstat(target.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG)
    }

    // MARK: Replacing it

    /// An update replaces the launcher with a new file renamed over the old
    /// (a new inode), and leaves no temporary file behind.
    func testAnUpdateReplacesItAtomically() throws {
        let launcher = try XCTUnwrap(McpLauncher.install(repoPath: try tree("psyneuview-0.6.16"), supportDirectory: support))
        let before = inode(launcher)
        try McpLauncher.install(repoPath: try tree("psyneuview-0.6.17"), supportDirectory: support)

        XCTAssertNotEqual(inode(launcher), before)
        XCTAssertTrue(text(launcher).contains("psyneuview-0.6.17/backend"))
        XCTAssertFalse(text(launcher).contains("psyneuview-0.6.16"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: McpLauncher.folder(supportDirectory: support).path), ["psyneuview-mcp"])
    }

    /// Starting the same version again doesn't rewrite the file.
    func testAnUnchangedLauncherIsLeftAlone() throws {
        let t = try tree("v1")
        let launcher = try XCTUnwrap(McpLauncher.install(repoPath: t, supportDirectory: support))
        let before = inode(launcher)
        try McpLauncher.install(repoPath: t, supportDirectory: support)
        XCTAssertEqual(inode(launcher), before)
    }

    /// A PsyNeuView without the MCP command gets no launcher, and a launcher
    /// left from a newer version is removed so the setup can't name a tree
    /// that isn't in use.
    func testATreeWithoutTheMcpCommandGetsNoLauncher() throws {
        let launcher = try XCTUnwrap(McpLauncher.install(repoPath: try tree("new"), supportDirectory: support))
        XCTAssertNil(try McpLauncher.install(repoPath: try tree("old", withMcp: false), supportDirectory: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.path))
    }

    func testRemoveIsQuietWhenThereIsNothing() throws {
        XCTAssertNoThrow(try McpLauncher.remove(supportDirectory: support))
    }

    func testRemoveTakesAwayALinkNotItsTarget() throws {
        let victim = root.appendingPathComponent("victim")
        try Data("keep me".utf8).write(to: victim)
        try FileManager.default.createDirectory(
            at: McpLauncher.folder(supportDirectory: support), withIntermediateDirectories: true)
        let target = McpLauncher.path(supportDirectory: support)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)

        try McpLauncher.remove(supportDirectory: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(text(victim), "keep me")
    }
}
