import XCTest
@testable import PsyNeuView

/// What setup finds in the folder it is about to install into (#131).
///
/// The old check asked "is there a Makefile here?", which answers "is this our
/// checkout?" and not "is there already something here". `~/Documents/PsyNeuView`
/// is a plausible name for someone's own folder, and it was installed into
/// without a word.
final class ExistingContentsTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-131-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String) throws {
        try "x".write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testEmptyDirectoryIsClear() {
        XCTAssertEqual(BundledPsyNeuView.existingContents(at: tmp), .clear)
    }

    func testDirectoryThatDoesNotExistIsClear() {
        let missing = tmp.appendingPathComponent("not-created")
        XCTAssertEqual(BundledPsyNeuView.existingContents(at: missing), .clear)
    }

    func testAMakefileMeansOurCheckout() throws {
        try write("Makefile")
        XCTAssertEqual(BundledPsyNeuView.existingContents(at: tmp), .psyNeuViewCheckout)
    }

    func testSomeoneElsesFilesAreReported() throws {
        // The case that used to pass silently.
        try write("my-notes.md")
        try write("draft-model.py")
        XCTAssertEqual(BundledPsyNeuView.existingContents(at: tmp), .otherFiles)
    }

    func testDotFilesAloneDoNotCount() throws {
        // Warning about .DS_Store would train people to click through the
        // warning that matters.
        try write(".DS_Store")
        XCTAssertEqual(BundledPsyNeuView.existingContents(at: tmp), .clear)
    }

    func testOurCheckoutWinsOverOtherFiles() throws {
        // A real checkout has plenty of other files in it; it must still be
        // reported as ours, because the advice differs.
        try write("Makefile")
        try write("README.md")
        XCTAssertEqual(BundledPsyNeuView.existingContents(at: tmp), .psyNeuViewCheckout)
    }

    func testTheOldHelperStillAnswersTheSameQuestion() throws {
        try write("Makefile")
        XCTAssertTrue(BundledPsyNeuView.wouldAdoptExistingCheckout(at: tmp))
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("Makefile"))
        try write("unrelated.txt")
        // Not a checkout — so adoption is the wrong word for it, even though
        // the folder is not empty.
        XCTAssertFalse(BundledPsyNeuView.wouldAdoptExistingCheckout(at: tmp))
    }
}
