import XCTest
@testable import PsyNeuView

/// The Setup Wizard's "Clone a new checkout" rules (#190).
final class PsyNeuLinkCloneTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnl-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The destination folder

    func testANewFolderIsClonedInto() {
        XCTAssertEqual(PsyNeuLinkClone.plan(destination: root.appendingPathComponent("PsyNeuLink").path), .clone)
    }

    func testAnEmptyFolderIsClonedInto() throws {
        let dir = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Finder's bookkeeping doesn't count.
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".DS_Store").path, contents: Data())
        XCTAssertEqual(PsyNeuLinkClone.plan(destination: dir.path), .clone)
    }

    func testAFolderWithAnythingElseInItIsRefused() throws {
        let dir = root.appendingPathComponent("busy")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data())
        guard case .refuse = PsyNeuLinkClone.plan(destination: dir.path) else {
            return XCTFail("never clone into a folder that already has things in it")
        }
    }

    func testAFolderThatIsAlreadyACheckoutIsUsedNotCloned() throws {
        let dir = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("psyneulink"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("setup.py").path, contents: Data())
        XCTAssertEqual(PsyNeuLinkClone.plan(destination: dir.path), .useExisting)
    }

    func testAFileIsRefused() {
        let file = root.appendingPathComponent("a-file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        guard case .refuse = PsyNeuLinkClone.plan(destination: file.path) else {
            return XCTFail("a file is not a folder to clone into")
        }
    }

    func testNoFolderIsRefused() {
        guard case .refuse = PsyNeuLinkClone.plan(destination: "  ") else {
            return XCTFail("an empty destination must not clone")
        }
    }

    // MARK: Repository and branch

    func testRepositoriesAreOwnerSlashName() {
        XCTAssertTrue(PsyNeuLinkClone.isValidRepo("PrincetonUniversity/PsyNeuLink"))
        XCTAssertTrue(PsyNeuLinkClone.isValidRepo("jonhanke-nam/PsyNeuLink"))
        XCTAssertTrue(PsyNeuLinkClone.isValidRepo("some.user/psy_neu-link"))
        XCTAssertFalse(PsyNeuLinkClone.isValidRepo("PsyNeuLink"))
        XCTAssertFalse(PsyNeuLinkClone.isValidRepo("a/b/c"))
        XCTAssertFalse(PsyNeuLinkClone.isValidRepo("../x"))
        XCTAssertFalse(PsyNeuLinkClone.isValidRepo("owner/na me"))
        XCTAssertFalse(PsyNeuLinkClone.isValidRepo("https://github.com/a/b"))
    }

    func testBranches() {
        XCTAssertTrue(PsyNeuLinkClone.isValidBranch("devel"))
        XCTAssertTrue(PsyNeuLinkClone.isValidBranch("jonhanke-dev-branches/x"))
        XCTAssertFalse(PsyNeuLinkClone.isValidBranch(""))
        XCTAssertFalse(PsyNeuLinkClone.isValidBranch("--upload-pack=evil"))
        XCTAssertFalse(PsyNeuLinkClone.isValidBranch("a b"))
    }

    // MARK: The command

    func testTheCloneCommand() {
        XCTAssertEqual(
            PsyNeuLinkClone.cloneArguments(
                repo: "PrincetonUniversity/PsyNeuLink", branch: "devel", destination: "/tmp/PNL"),
            ["clone", "--filter=blob:none", "--branch", "devel", "--",
             "https://github.com/PrincetonUniversity/PsyNeuLink.git", "/tmp/PNL"])
    }

    // MARK: The wizard's choices

    func testACloneInstallsAsALocalCheckout() {
        XCTAssertEqual(PsyNeuLinkChoice.clone.source, .local)
        XCTAssertEqual(PsyNeuLinkChoice.existing.source, .local)
        XCTAssertEqual(PsyNeuLinkChoice(.github), .github)
    }
}
