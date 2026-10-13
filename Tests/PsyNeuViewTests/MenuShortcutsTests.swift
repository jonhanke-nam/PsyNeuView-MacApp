import AppKit
import XCTest
@testable import PsyNeuView

// The menu must not claim keys the web app needs (#123).
// XCTest (not Swift Testing) so it runs on the CI toolchain's Xcode.

final class MenuShortcutsTests: XCTestCase {

    func testNoBindingShadowsTheWebApp() {
        // The invariant this file exists for. AppKit matches menu key
        // equivalents before the WKWebView sees the event, so a bare Cmd key
        // taken here is one the app itself can never use.
        XCTAssertEqual(
            MenuShortcuts.conflicts.map(\.key), [],
            "the menu is claiming a key the web app needs")
    }

    func testTheOriginalBugsAreGone() {
        // Cmd+X stopped the backend; Cmd+S started services instead of saving.
        XCTAssertNotEqual(MenuShortcuts.startServices, MenuShortcuts.Binding("s"))
        XCTAssertEqual(MenuShortcuts.startServices.modifiers, [.command, .control])
        XCTAssertEqual(MenuShortcuts.restartServices.modifiers, [.command, .control])
    }

    func testCutKeepsTheStandardKey() {
        // Cmd+X belongs to Cut. It reaches the web view through the responder
        // chain, which is the whole point of putting it in an Edit menu.
        XCTAssertEqual(MenuShortcuts.cut, MenuShortcuts.Binding("x"))
        XCTAssertTrue(MenuShortcuts.cut.isBareCommand)
    }

    func testStopServicesHasNoShortcut() {
        // Destructive, never urgent. Nothing in `all` should bind it, and the
        // absence is deliberate rather than an oversight.
        XCTAssertFalse(MenuShortcuts.all.contains(MenuShortcuts.Binding("x", [.command, .control])))
    }

    func testSaveAndUndoAreLeftToTheApp() {
        let claimed = Set(MenuShortcuts.all.filter(\.isBareCommand).map(\.key))
        XCTAssertFalse(claimed.contains("s"), "Cmd+S must reach the editor's save")
        XCTAssertFalse(claimed.contains("z"), "Cmd+Z must reach the model-wide undo")
        XCTAssertFalse(claimed.contains("r"), "Cmd+R must not be swallowed by the menu")
    }

    func testThePlannedShortcutsAreStillFree() {
        // PsyNeuView-archive#1112 wants these. Listing them in reservedForTheWebApp
        // means the menu cannot take one back before they are built.
        let claimed = Set(MenuShortcuts.all.filter(\.isBareCommand).map(\.key))
        for key in ["i", "o", "f", "1", "2", "3", "4", "5", "6", "7"] {
            XCTAssertFalse(claimed.contains(key), "Cmd+\(key) was reserved for the web app")
        }
    }

    func testZoomUsesTheBrowserKeys() {
        // ⌘+ / ⌘= / ⌘- / ⌘0, as in every browser (#178).
        for b in [MenuShortcuts.zoomIn, MenuShortcuts.zoomInUnshifted,
                  MenuShortcuts.zoomOut, MenuShortcuts.actualSize] {
            XCTAssertTrue(MenuShortcuts.all.contains(b))
            XCTAssertTrue(b.isBareCommand)
        }
    }

    func testNoTwoBindingsCollide() {
        // Two menu items on the same chord is a bug wherever it happens.
        let pairs = MenuShortcuts.all.map { "\($0.key)|\($0.modifiers.rawValue)" }
        XCTAssertEqual(pairs.count, Set(pairs).count, "duplicate key equivalent")
    }

    func testBareCommandIsRecognised() {
        XCTAssertTrue(MenuShortcuts.Binding("k").isBareCommand)
        XCTAssertFalse(MenuShortcuts.Binding("k", [.command, .control]).isBareCommand)
        XCTAssertFalse(MenuShortcuts.Binding("k", [.command, .shift]).isBareCommand)
    }
}

/// The App menu's two update items act on different things — Sparkle replaces
/// the application, the other pulls the checkout it runs — and read as one
/// offer when both just say "update". Each now shows what it is at (#167):
/// the checkout item names the folder it pulls and the branch that folder is
/// on, and is a developer item, hidden outside developer mode (#214).
final class UpdateMenuTitlesTests: XCTestCase {

    private let home = "/Users/someone"

    func testTheTwoTitlesAreTellableApart() {
        let app = UpdateMenuTitles.appUpdate(installedVersion: "0.5.11")
        let code = UpdateMenuTitles.codeUpdate(
            path: "/Users/someone/Documents/PsyNeuView", branch: "devel", tracksGit: true,
            home: home)
        XCTAssertEqual(app, "Check for App Updates... (0.5.11)")
        XCTAssertEqual(code, "Update PsyNeuView checkout (~/Documents/PsyNeuView @ devel)…")
        XCTAssertNotEqual(app, code)
    }

    /// The folder is shortened with `~`, as people write paths; one outside
    /// the home folder is shown as it is.
    func testTheFolderIsAbbreviatedWithATilde() {
        XCTAssertEqual(
            UpdateMenuTitles.codeUpdate(
                path: "/Users/someone/code/PsyNeuView/", branch: "main", tracksGit: true,
                home: home),
            "Update PsyNeuView checkout (~/code/PsyNeuView @ main)…")
        XCTAssertEqual(
            UpdateMenuTitles.codeUpdate(
                path: "/opt/PsyNeuView", branch: "devel", tracksGit: true, home: home),
            "Update PsyNeuView checkout (/opt/PsyNeuView @ devel)…")
    }

    /// A checkout whose branch cannot be read (detached HEAD, unreadable
    /// `.git`) is still named by its folder, without an " @ " to nothing.
    func testACheckoutWithNoReadableBranchIsNamedByItsFolder() {
        XCTAssertEqual(
            UpdateMenuTitles.codeUpdate(
                path: "/Users/someone/Documents/PsyNeuView", branch: nil, tracksGit: true,
                home: home),
            "Update PsyNeuView checkout (~/Documents/PsyNeuView)…")
        XCTAssertEqual(
            UpdateMenuTitles.codeUpdate(
                path: "/Users/someone/Documents/PsyNeuView", branch: "  ", tracksGit: true,
                home: home),
            "Update PsyNeuView checkout (~/Documents/PsyNeuView)…")
    }

    /// A bundled install has no checkout: PsyNeuView arrives with the app, and
    /// the item is disabled. Naming a folder and branch it does not have would
    /// be a lie, so the title stays plain whatever is passed.
    func testABundledInstallNamesNoFolderOrBranch() {
        XCTAssertEqual(
            UpdateMenuTitles.codeUpdate(
                path: "/Users/someone/Library/Application Support/PsyNeuView/psyneuview-0.5.10",
                branch: "devel", tracksGit: false, home: home),
            "Update PsyNeuView checkout…")
    }

    /// An unreadable value leaves the plain title. An empty parenthesis reads
    /// as a value that is itself empty, rather than one that could not be read.
    func testMissingValuesLeaveThePlainTitle() {
        XCTAssertEqual(
            UpdateMenuTitles.appUpdate(installedVersion: nil),
            "Check for App Updates...")
        XCTAssertEqual(
            UpdateMenuTitles.appUpdate(installedVersion: "   "),
            "Check for App Updates...")
        XCTAssertEqual(
            UpdateMenuTitles.codeUpdate(path: nil, branch: "devel", tracksGit: true, home: home),
            "Update PsyNeuView checkout…")
        XCTAssertEqual(
            UpdateMenuTitles.codeUpdate(path: "  ", branch: "devel", tracksGit: true, home: home),
            "Update PsyNeuView checkout…")
    }

    /// Whatever the detail, the item is still recognisably the same command —
    /// the detail sits inside the title, before the ellipsis, and the plain
    /// title's words survive it.
    func testTheBaseTitleSurvivesTheDetail() {
        let stem = String(UpdateMenuTitles.codeUpdateBase.dropLast())
        for branch in ["devel", "main", "feature/a-very-long-branch-name"] {
            let title = UpdateMenuTitles.codeUpdate(
                path: "/Users/someone/PsyNeuView", branch: branch, tracksGit: true, home: home)
            XCTAssertTrue(title.hasPrefix(stem), title)
            XCTAssertTrue(title.hasSuffix("…"), title)
        }
        XCTAssertTrue(
            UpdateMenuTitles.appUpdate(installedVersion: "0.5.11")
                .hasPrefix(UpdateMenuTitles.appUpdateBase))
    }

    /// The checkout item is a developer item: hidden, not just disabled, for
    /// everyone else (#214). The menu applies this on every change of the
    /// setting and every time it opens; this is the rule it applies.
    func testTheCheckoutItemIsShownOnlyInDeveloperMode() {
        XCTAssertFalse(UpdateMenuTitles.showsCodeUpdate(developerMode: false))
        XCTAssertTrue(UpdateMenuTitles.showsCodeUpdate(developerMode: true))
    }
}
