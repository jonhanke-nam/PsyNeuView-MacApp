import XCTest
@testable import PsyNeuView

/// Models are only moved out of folders the app owns, never out of a checkout (#199).
final class ModelRescueTests: XCTestCase {

    private var root: URL!
    private var support: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rescue-\(UUID().uuidString)")
        support = root.appendingPathComponent("Application Support/PsyNeuView")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tree(_ url: URL, git: Bool = false, makefile: Bool = false, model: Bool = true) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("models"), withIntermediateDirectories: true)
        if git { try fm.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true) }
        if makefile { fm.createFile(atPath: url.appendingPathComponent("Makefile").path, contents: Data()) }
        if model { fm.createFile(atPath: url.appendingPathComponent("models/mine.py").path, contents: Data("x = 1\n".utf8)) }
        return url
    }

    func testAnUnpackedBundledFolderIsAppOwned() throws {
        let t = try tree(support.appendingPathComponent("psyneuview-0.5.8"))
        XCTAssertTrue(BundledPsyNeuView.isAppOwnedTree(t, supportDirectory: support))
    }

    func testAGitCheckoutIsNeverAppOwned() throws {
        let t = try tree(home.appendingPathComponent("PsyNeuView"), git: true)
        XCTAssertFalse(BundledPsyNeuView.isAppOwnedTree(t, supportDirectory: support))
    }

    func testACheckoutWithoutGitOutsideTheSupportFolderIsNotAppOwned() throws {
        let t = try tree(home.appendingPathComponent("PsyNeuView-copy"), makefile: true)
        XCTAssertFalse(BundledPsyNeuView.isAppOwnedTree(t, supportDirectory: support))
    }

    func testAGitCheckoutInsideTheSupportFolderIsStillNotAppOwned() throws {
        let t = try tree(support.appendingPathComponent("psyneuview-dev"), git: true)
        XCTAssertFalse(BundledPsyNeuView.isAppOwnedTree(t, supportDirectory: support))
    }

    func testANameThatOnlyStartsLikeTheSupportFolderIsNotInsideIt() throws {
        let t = try tree(root.appendingPathComponent("Application Support/PsyNeuView-other/x"))
        XCTAssertFalse(BundledPsyNeuView.isAppOwnedTree(t, supportDirectory: support))
    }

    func testModelsInACheckoutStayWhereTheUserPutThem() throws {
        let t = try tree(home.appendingPathComponent("PsyNeuView"), git: true)
        XCTAssertEqual(BundledPsyNeuView.rescueUserModels(fromTree: t, supportDirectory: support), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.appendingPathComponent("models/mine.py").path))
    }
}
