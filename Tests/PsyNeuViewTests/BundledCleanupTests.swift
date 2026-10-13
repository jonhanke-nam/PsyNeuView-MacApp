import XCTest
@testable import PsyNeuView

/// Which older included PsyNeuView folders go after a move (#239).
final class BundledCleanupTests: XCTestCase {

    private let support = URL(fileURLWithPath: "/Users/tester/Library/Application Support/PsyNeuView")

    private func tree(_ version: String) -> URL {
        support.appendingPathComponent("psyneuview-\(version)")
    }

    /// An unpacked tree, stamped with the version its name says.
    private func unpacked(_ version: String) -> BundledCleanup.Folder {
        BundledCleanup.Folder(url: tree(version), stampedVersion: version, isCheckout: false)
    }

    private func verdicts(_ entries: [BundledCleanup.Entry]) -> [String: BundledCleanup.Verdict] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.url.lastPathComponent, $0.verdict) })
    }

    private func isKept(_ verdict: BundledCleanup.Verdict?) -> Bool {
        if case .keep = verdict { return true }
        return false
    }

    // MARK: The plan

    /// The reported shape: three old versions, a move from 0.5.10 to 0.5.15.
    /// The one in use and the one moved from stay; the rest go.
    func testOlderVersionsGoButInUseAndFallbackStay() {
        let entries = BundledCleanup.plan(
            folders: ["0.5.6", "0.5.8", "0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        let v = verdicts(entries)
        XCTAssertEqual(v["psyneuview-0.5.15"], .keep("in use"))
        XCTAssertEqual(v["psyneuview-0.5.10"], .keep("the previous version, kept as a fallback"))
        XCTAssertEqual(v["psyneuview-0.5.8"], .remove)
        XCTAssertEqual(v["psyneuview-0.5.6"], .remove)
    }

    func testNothingToDoWithOnlyTheTwo() {
        let entries = BundledCleanup.plan(
            folders: ["0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        XCTAssertFalse(entries.contains { $0.verdict == .remove })
    }

    /// The saved install is never removed, even when it isn't the one running.
    func testTheSavedInstallIsKept() {
        let entries = BundledCleanup.plan(
            folders: ["0.5.6", "0.5.8", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.6"), movedFrom: tree("0.5.8"))
        XCTAssertEqual(verdicts(entries)["psyneuview-0.5.6"], .keep("the saved install"))
    }

    /// A git checkout (or a Makefile tree) named like ours is someone's own.
    func testACheckoutIsNeverRemoved() {
        var checkout = unpacked("0.5.6")
        checkout.isCheckout = true
        let entries = BundledCleanup.plan(
            folders: [checkout] + ["0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        XCTAssertEqual(verdicts(entries)["psyneuview-0.5.6"], .keep("a checkout"))
    }

    func testAFolderWithoutAStampIsNeverRemoved() {
        var unstamped = unpacked("0.5.6")
        unstamped.stampedVersion = nil
        let entries = BundledCleanup.plan(
            folders: [unstamped] + ["0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        XCTAssertTrue(isKept(verdicts(entries)["psyneuview-0.5.6"]))
    }

    func testAStampThatDisagreesWithTheNameIsKept() {
        var odd = unpacked("0.5.6")
        odd.stampedVersion = "0.5.7"
        let entries = BundledCleanup.plan(
            folders: [odd] + ["0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        XCTAssertTrue(isKept(verdicts(entries)["psyneuview-0.5.6"]))
    }

    func testALinkIsNeverFollowedOrRemoved() {
        var link = unpacked("0.5.6")
        link.isSymlink = true
        let entries = BundledCleanup.plan(
            folders: [link] + ["0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        XCTAssertTrue(isKept(verdicts(entries)["psyneuview-0.5.6"]))
    }

    /// Edited copies the backend couldn't move out keep their folder.
    func testAFolderHoldingSomeonesFilesIsKept() {
        var withWork = unpacked("0.5.6")
        withWork.leftoverFiles = ["backend/Stroop.py"]
        let entries = BundledCleanup.plan(
            folders: [withWork] + ["0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        XCTAssertEqual(verdicts(entries)["psyneuview-0.5.6"],
                       .keep("holds files that may be yours: backend/Stroop.py"))
    }

    /// Anything not named `psyneuview-<version>` isn't the app's and isn't listed.
    func testOtherFoldersAreNotConsidered() {
        let other = BundledCleanup.Folder(
            url: support.appendingPathComponent("notes"), stampedVersion: "0.5.6", isCheckout: false)
        let bare = BundledCleanup.Folder(
            url: support.appendingPathComponent("psyneuview-"), stampedVersion: nil, isCheckout: false)
        let entries = BundledCleanup.plan(
            folders: [other, bare, unpacked("0.5.15")],
            inUse: tree("0.5.15"), savedInstall: nil, movedFrom: nil)
        XCTAssertEqual(entries.map { $0.url.lastPathComponent }, ["psyneuview-0.5.15"])
    }

    /// Moved from somewhere outside the support folder: the newest older
    /// version stays as the fallback, compared as numbers (0.5.10 > 0.5.9).
    func testWithoutTheMovedFromFolderTheNewestOlderOneIsKept() {
        let entries = BundledCleanup.plan(
            folders: ["0.5.8", "0.5.9", "0.5.10", "0.5.15"].map(unpacked),
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"),
            movedFrom: URL(fileURLWithPath: "/somewhere/else/psyneuview-0.5.4"))
        let v = verdicts(entries)
        XCTAssertEqual(v["psyneuview-0.5.10"], .keep("the newest previous version, kept as a fallback"))
        XCTAssertEqual(v["psyneuview-0.5.9"], .remove)
        XCTAssertEqual(v["psyneuview-0.5.8"], .remove)
    }

    /// The move's folder kept for another reason is still the fallback: no
    /// second one is held back.
    func testTheMovedFromFolderIsTheFallbackWhateverElseIsTrue() {
        var previous = unpacked("0.5.10")
        previous.leftoverFiles = ["models/mine.py"]
        let entries = BundledCleanup.plan(
            folders: [unpacked("0.5.8"), previous, unpacked("0.5.15")],
            inUse: tree("0.5.15"), savedInstall: tree("0.5.15"), movedFrom: tree("0.5.10"))
        XCTAssertEqual(verdicts(entries)["psyneuview-0.5.8"], .remove)
    }

    // MARK: Leftovers

    func testLeftoversAreWorkFilesTheCurrentVersionDoesNotShip() {
        let found = BundledCleanup.leftovers(
            oldBackend: ["app", "pyproject.toml", "test_model.py", "test_model.pnlview.json",
                         "Stroop.py", "Stroop.pnlview.json", "Stroop.labels.yaml",
                         "psynewview.egg-info", ".psyneuview/Stroop.psyneuview.json"],
            shippedBackend: ["app", "pyproject.toml", "test_model.py", "test_model.pnlview.json"],
            oldModels: ["README.md", "sub/README.md", "sub/mine.py"])
        XCTAssertEqual(Set(found), [
            "backend/Stroop.py", "backend/Stroop.pnlview.json", "backend/Stroop.labels.yaml",
            "backend/.psyneuview/Stroop.psyneuview.json", "models/sub/mine.py",
        ])
    }

    func testAFreshTreeHasNoLeftovers() {
        let shipped = ["app", "demos", "pyproject.toml", "test_model.py"]
        XCTAssertTrue(BundledCleanup.leftovers(
            oldBackend: shipped, shippedBackend: Set(shipped), oldModels: ["README.md"]).isEmpty)
    }

    func testFolderVersion() {
        XCTAssertEqual(BundledCleanup.version(fromFolderName: "psyneuview-0.5.8"), "0.5.8")
        XCTAssertNil(BundledCleanup.version(fromFolderName: "psyneuview-"))
        XCTAssertNil(BundledCleanup.version(fromFolderName: "PsyNeuView"))
    }

    // MARK: Survey, on real folders

    /// What `survey` reads off disk feeds the plan the same way. Nothing is
    /// removed here: `apply` is not called on a remove verdict.
    func testSurveyReadsStampsCheckoutsAndLeftovers() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("BundledCleanupTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }

        func make(_ name: String, stamp: String?, files: [String] = []) throws -> URL {
            let dir = root.appendingPathComponent(name)
            try fm.createDirectory(at: dir.appendingPathComponent("backend"),
                                   withIntermediateDirectories: true)
            try "".write(to: dir.appendingPathComponent("backend/pyproject.toml"),
                         atomically: true, encoding: .utf8)
            if let stamp {
                try "version=\(stamp)\n".write(to: dir.appendingPathComponent("BUNDLED_VERSION"),
                                               atomically: true, encoding: .utf8)
            }
            for file in files {
                let url = dir.appendingPathComponent(file)
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try "".write(to: url, atomically: true, encoding: .utf8)
            }
            return dir
        }

        let inUse = try make("psyneuview-0.5.15", stamp: "0.5.15")
        _ = try make("psyneuview-0.5.10", stamp: "0.5.10")
        _ = try make("psyneuview-0.5.8", stamp: "0.5.8", files: ["models/README.md"])
        _ = try make("psyneuview-0.5.7", stamp: "0.5.7", files: ["backend/Stroop.py"])
        _ = try make("psyneuview-0.5.6", stamp: "0.5.6", files: [".git/HEAD"])
        _ = try make("psyneuview-0.5.5", stamp: nil)
        _ = try make("something-else", stamp: "0.5.4")

        let folders = BundledCleanup.survey(support: root, inUse: inUse)
        XCTAssertEqual(folders.map { $0.url.lastPathComponent }, [
            "psyneuview-0.5.10", "psyneuview-0.5.15", "psyneuview-0.5.5",
            "psyneuview-0.5.6", "psyneuview-0.5.7", "psyneuview-0.5.8",
        ])

        let v = verdicts(BundledCleanup.plan(
            folders: folders, inUse: inUse, savedInstall: inUse,
            movedFrom: root.appendingPathComponent("psyneuview-0.5.10")))
        XCTAssertEqual(v["psyneuview-0.5.15"], .keep("in use"))
        XCTAssertEqual(v["psyneuview-0.5.10"], .keep("the previous version, kept as a fallback"))
        XCTAssertEqual(v["psyneuview-0.5.8"], .remove)
        XCTAssertEqual(v["psyneuview-0.5.7"], .keep("holds files that may be yours: backend/Stroop.py"))
        XCTAssertEqual(v["psyneuview-0.5.6"], .keep("a checkout"))
        XCTAssertTrue(isKept(v["psyneuview-0.5.5"]))
        XCTAssertNil(v["something-else"])
    }

    /// Kept folders are reported, not touched.
    func testApplyLeavesKeptFoldersAlone() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("BundledCleanupTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let lines = BundledCleanup.apply([.init(url: dir, verdict: .keep("in use"))])
        XCTAssertEqual(lines, ["  kept \(dir.lastPathComponent): in use"])
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }
}
