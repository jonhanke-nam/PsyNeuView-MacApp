import Foundation
import XCTest

@testable import PsyNeuView

/// The test app and the real app never share a name, a folder or a setting
/// (#209).
///
/// Before this, a test build carried the real app's identity: it read and
/// wrote the real settings, unpacked into the real Application Support
/// folder, and could not run beside the real app. Every path and name now
/// comes from `AppIdentity`, and these tests hold both identities side by
/// side.
final class AppIdentityTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")
    private var library: URL { home.appendingPathComponent("Library") }
    private var support: URL { library.appendingPathComponent("Application Support") }

    private func paths(_ identity: AppIdentity) -> [String] {
        identity.ownedPaths(home: home, library: library, applicationSupport: support)
            .map(\.path)
    }

    // MARK: Which app

    func testTheTestBundleIdIsTheOnlyThingThatMakesATestBuild() {
        XCTAssertEqual(AppIdentity.from(bundleIdentifier: "com.psyneuview.macapp.test"), .test)
        XCTAssertEqual(AppIdentity.from(bundleIdentifier: "com.psyneuview.macapp"), .release)
        // `swift run` has no bundle; an unknown id (the XCTest host) is not a test build either.
        XCTAssertEqual(AppIdentity.from(bundleIdentifier: nil), .release)
        XCTAssertEqual(AppIdentity.from(bundleIdentifier: "com.apple.dt.xctest.tool"), .release)
    }

    func testTheBundleIdsRoundTrip() {
        XCTAssertEqual(AppIdentity.release.bundleIdentifier, "com.psyneuview.macapp")
        XCTAssertEqual(AppIdentity.test.bundleIdentifier, "com.psyneuview.macapp.test")
        for identity in [AppIdentity.release, .test] {
            XCTAssertEqual(AppIdentity.from(bundleIdentifier: identity.bundleIdentifier), identity)
        }
    }

    // MARK: Names

    func testNamesSayWhichAppThisIs() {
        XCTAssertEqual(AppIdentity.release.displayName, "PsyNeuView")
        XCTAssertEqual(AppIdentity.test.displayName, "PsyNeuView Test")
        XCTAssertEqual(AppIdentity.release.folderName, "PsyNeuView")
        XCTAssertEqual(AppIdentity.test.folderName, "PsyNeuView-Test")
    }

    /// The real app's title is exactly what it was; the test app's names the
    /// build, so a glance at the window says which copy this is.
    func testWindowTitle() {
        XCTAssertEqual(AppIdentity.release.windowTitle(version: "0.5.19"), "PsyNeuView")
        XCTAssertEqual(AppIdentity.test.windowTitle(version: "0.5.19"), "PsyNeuView Test 0.5.19")
        XCTAssertEqual(AppIdentity.test.windowTitle(version: nil), "PsyNeuView Test")
        XCTAssertEqual(AppIdentity.test.windowTitle(version: ""), "PsyNeuView Test")
    }

    func testKeychainServicesDiffer() {
        XCTAssertEqual(AppIdentity.release.keychainService, "com.psyneuview.macapp.github-token")
        XCTAssertEqual(AppIdentity.test.keychainService, "com.psyneuview.macapp.test.github-token")
    }

    // MARK: Folders

    /// The real app's paths are the ones every existing install already has.
    func testTheRealAppsPathsAreUnchanged() {
        let r = AppIdentity.release
        XCTAssertEqual(r.supportDirectory(applicationSupport: support).path,
                       "/Users/tester/Library/Application Support/PsyNeuView")
        XCTAssertEqual(r.logsDirectory(library: library).path, "/Users/tester/Library/Logs/PsyNeuView")
        XCTAssertEqual(r.stateDirectory(home: home).path, "/Users/tester/.psyneuview")
        XCTAssertEqual(r.configFile(home: home).path, "/Users/tester/.psynewview.json")
        XCTAssertEqual(r.cloneRoot(home: home).path, "/Users/tester/.psyneuview/sources")
        XCTAssertEqual(r.workingCopiesDirectory(home: home).path, "/Users/tester/.psyneuview/working-copies")
        XCTAssertEqual(r.layoutsDirectory(home: home).path, "/Users/tester/.psyneuview/layouts")
        XCTAssertEqual(r.userModelsDirectory(home: home).path, "/Users/tester/.psyneuview/models")
        XCTAssertEqual(r.defaultCheckoutDirectory(home: home).path, "/Users/tester/Documents/PsyNeuView")
        XCTAssertEqual(r.defaultProjectFolder(home: home).path, "/Users/tester/Documents/PsyNeuView-My-Models")
    }

    func testTheTestAppsPathsAreItsOwn() {
        let t = AppIdentity.test
        XCTAssertEqual(t.supportDirectory(applicationSupport: support).path,
                       "/Users/tester/Library/Application Support/PsyNeuView-Test")
        XCTAssertEqual(t.logsDirectory(library: library).path, "/Users/tester/Library/Logs/PsyNeuView-Test")
        XCTAssertEqual(t.stateDirectory(home: home).path, "/Users/tester/.psyneuview-test")
        XCTAssertEqual(t.configFile(home: home).path, "/Users/tester/.psyneuview-test/psynewview.json")
        XCTAssertEqual(t.cloneRoot(home: home).path, "/Users/tester/.psyneuview-test/sources")
        XCTAssertEqual(t.workingCopiesDirectory(home: home).path, "/Users/tester/.psyneuview-test/working-copies")
        XCTAssertEqual(t.layoutsDirectory(home: home).path, "/Users/tester/.psyneuview-test/layouts")
        XCTAssertEqual(t.userModelsDirectory(home: home).path, "/Users/tester/.psyneuview-test/models")
        XCTAssertEqual(t.defaultCheckoutDirectory(home: home).path, "/Users/tester/Documents/PsyNeuView-Test")
        XCTAssertEqual(t.defaultProjectFolder(home: home).path, "/Users/tester/Documents/PsyNeuView-Test-Models")
    }

    /// The one that matters: no path of one app is a path of the other, and
    /// no path of one app is inside a folder of the other.
    func testNoPathIsSharedOrNested() {
        let real = paths(.release)
        let test = paths(.test)
        XCTAssertEqual(real.count, test.count)
        XCTAssertFalse(real.isEmpty)
        for r in real {
            for t in test {
                XCTAssertNotEqual(r, t, "shared path: \(r)")
                XCTAssertFalse(t.hasPrefix(r + "/"), "\(t) is inside the real app's \(r)")
                XCTAssertFalse(r.hasPrefix(t + "/"), "\(r) is inside the test app's \(t)")
            }
        }
    }

    /// `BundledPsyNeuView`, `LaunchLog` and the others ask the identity rather
    /// than building paths of their own.
    func testTheServicesUseTheIdentitysFolders() {
        XCTAssertEqual(BundledPsyNeuView.supportDirectory(identity: .test).lastPathComponent, "PsyNeuView-Test")
        XCTAssertEqual(BundledPsyNeuView.supportDirectory(identity: .release).lastPathComponent, "PsyNeuView")
        XCTAssertEqual(BundledPsyNeuView.userModelsDirectory(identity: .test).path,
                       AppIdentity.test.userModelsDirectory().path)
        XCTAssertEqual(BundledPsyNeuView.userModelsDirectory(identity: .release).path,
                       AppIdentity.release.userModelsDirectory().path)
    }

    // MARK: The backend

    func testBothAppsTellTheBackendTheirFlavor() {
        XCTAssertEqual(AppIdentity.release.backendOverrides(home: home)["PSYNEUVIEW_APP_FLAVOR"], "release")
        XCTAssertEqual(AppIdentity.test.backendOverrides(home: home)["PSYNEUVIEW_APP_FLAVOR"], "test")
    }

    /// The real app sets no path: PsyNeuView's defaults are what every
    /// existing install uses, and naming them here would be a second copy.
    func testTheRealAppLeavesPsyNeuViewsDefaultsAlone() {
        let env = AppIdentity.release.backendOverrides(home: home)
        XCTAssertEqual(env.keys.sorted(), ["PSYNEUVIEW_APP_FLAVOR"])
    }

    /// The test app points every backend folder PsyNeuView lets it point
    /// at into its own state folder; the models folder is deliberately not
    /// among them (`PSYNEWVIEW_MODELS_DIR` would fix it and disable Move…).
    func testTheTestAppPointsTheBackendAtItsOwnFolders() {
        let env = AppIdentity.test.backendOverrides(home: home)
        XCTAssertEqual(env["PSYNEUVIEW_CONFIG_FILE"], "/Users/tester/.psyneuview-test/psynewview.json")
        XCTAssertEqual(env["PSYNEUVIEW_CLONE_ROOT"], "/Users/tester/.psyneuview-test/sources")
        XCTAssertEqual(env["PSYNEWVIEW_WORKING_DIR"], "/Users/tester/.psyneuview-test/working-copies")
        XCTAssertEqual(env["PSYNEUVIEW_LAYOUTS_DIR"], "/Users/tester/.psyneuview-test/layouts")
        XCTAssertNil(env["PSYNEWVIEW_MODELS_DIR"])
        for value in env.values where value.hasPrefix("/") {
            XCTAssertTrue(value.hasPrefix("/Users/tester/.psyneuview-test/"), "outside the test state folder: \(value)")
        }
    }

    func testTheBackendEnvironmentCarriesTheOverrides() {
        let repo = URL(fileURLWithPath: "/tmp/psyneuview-test-tree")
        let release = ProcessManager.backendEnvironment(base: [:], repoPath: repo, identity: .release)
        XCTAssertEqual(release["PSYNEUVIEW_APP_FLAVOR"], "release")
        XCTAssertNil(release["PSYNEUVIEW_CONFIG_FILE"])
        XCTAssertNil(release["PSYNEUVIEW_CLONE_ROOT"])

        let test = ProcessManager.backendEnvironment(base: [:], repoPath: repo, identity: .test)
        XCTAssertEqual(test["PSYNEUVIEW_APP_FLAVOR"], "test")
        XCTAssertEqual(test["PSYNEUVIEW_CONFIG_FILE"], AppIdentity.test.configFile().path)
        XCTAssertEqual(test["PSYNEUVIEW_CLONE_ROOT"], AppIdentity.test.cloneRoot().path)
        XCTAssertEqual(test["PSYNEWVIEW_WORKING_DIR"], AppIdentity.test.workingCopiesDirectory().path)
        XCTAssertEqual(test["PSYNEUVIEW_LAYOUTS_DIR"], AppIdentity.test.layoutsDirectory().path)
        // Still the Mac app, as far as the backend's capabilities go.
        XCTAssertEqual(test["PSYNEUVIEW_DEPLOYMENT_MODE"], "mac_app")
    }

    // MARK: The project folder (#240)

    private func modelDirs(_ data: Data?) -> [String]? {
        guard let data,
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return dict["model_dirs"] as? [String]
    }

    /// The real app never writes PsyNeuView's settings for its folder.
    func testTheRealAppNeverSeedsAProjectFolder() {
        XCTAssertNil(AppIdentity.release.projectFolderSeed(existing: nil, home: home))
        XCTAssertNil(AppIdentity.release.projectFolderSeed(existing: Data("{}".utf8), home: home))
    }

    /// A first launch of the test app starts in its own folder.
    func testTheTestAppStartsInItsOwnProjectFolder() {
        let seed = AppIdentity.test.projectFolderSeed(existing: nil, home: home)
        XCTAssertEqual(modelDirs(seed?.settings), ["/Users/tester/Documents/PsyNeuView-Test-Models"])
        XCTAssertNotNil(AppIdentity.test.projectFolderSeed(existing: Data(), home: home))
    }

    /// Other settings in the file survive.
    func testSeedingKeepsTheRestOfTheSettings() throws {
        let existing = Data(#"{"catalogs": [{"id": "a"}], "model_dirs": []}"#.utf8)
        let seed = try XCTUnwrap(AppIdentity.test.projectFolderSeed(existing: existing, home: home))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: seed.settings) as? [String: Any])
        XCTAssertEqual((dict["catalogs"] as? [[String: String]])?.first?["id"], "a")
        XCTAssertEqual(dict["model_dirs"] as? [String], ["/Users/tester/Documents/PsyNeuView-Test-Models"])
    }

    /// A folder the tester chose stays chosen.
    func testAChosenFolderIsLeftAlone() {
        let existing = Data(#"{"model_dirs": ["/Users/tester/Desktop/try-this", "/x"]}"#.utf8)
        XCTAssertNil(AppIdentity.test.projectFolderSeed(existing: existing, home: home))
        let own = Data(#"{"model_dirs": ["/Users/tester/Documents/PsyNeuView-Test-Models"]}"#.utf8)
        XCTAssertNil(AppIdentity.test.projectFolderSeed(existing: own, home: home))
    }

    /// The real app's folders — the shared default, and the hidden legacy
    /// one PsyNeuView would adopt — are pointed away from; extra folders
    /// stay, and nothing says files moved.
    func testTheRealAppsFoldersArePointedAway() {
        for real in ["/Users/tester/Documents/PsyNeuView-My-Models",
                     "~/Documents/PsyNeuView-My-Models/",
                     "/Users/tester/.psyneuview/models"] {
            let existing = Data(#"{"model_dirs": ["\#(real)", "/x"]}"#.utf8)
            let seed = AppIdentity.test.projectFolderSeed(existing: existing, home: home)
            XCTAssertEqual(modelDirs(seed?.settings),
                           ["/Users/tester/Documents/PsyNeuView-Test-Models", "/x"], real)
            XCTAssertTrue(seed?.note.contains("No files were moved") ?? false)
        }
    }

    /// A file that isn't a JSON object isn't ours to rewrite.
    func testAnUnreadableSettingsFileIsLeftAlone() {
        XCTAssertNil(AppIdentity.test.projectFolderSeed(existing: Data("not json".utf8), home: home))
        XCTAssertNil(AppIdentity.test.projectFolderSeed(existing: Data("[1]".utf8), home: home))
    }

    // MARK: Updates

    func testOnlyTheRealAppUpdatesItself() {
        XCTAssertTrue(AppIdentity.release.updatesEnabled)
        XCTAssertFalse(AppIdentity.test.updatesEnabled)
        XCTAssertEqual(UpdateMenuTitles.appUpdate(installedVersion: "0.5.19", updatesEnabled: false),
                       "App updates are off in the test app (0.5.19)")
        XCTAssertEqual(UpdateMenuTitles.appUpdate(installedVersion: "0.5.19", updatesEnabled: true),
                       "Check for App Updates... (0.5.19)")
    }

    // MARK: About

    /// About names a test build as one, with the commit and where it runs
    /// from; the real app's first lines are exactly what they were.
    func testAboutSaysWhichCopyThisIs() {
        let real = VersionReport.aboutLines(
            appVersion: "0.5.19", appBuild: "0.5.19", psyNeuViewVersion: "0.5.10", checkoutPath: nil,
            psyNeuLinkVersion: nil, psyNeuLinkSource: nil, availableSources: [],
            identity: .release, buildCommit: "abc1234",
            bundlePath: "/Applications/PsyNeuView.app",
            dataFolder: "~/Library/Application Support/PsyNeuView")
        XCTAssertEqual(real[0], "PsyNeuView app 0.5.19, built from commit abc1234")
        XCTAssertEqual(real[1], "PsyNeuView 0.5.10, included with this app")
        XCTAssertTrue(real.contains("Running from /Applications/PsyNeuView.app"))
        XCTAssertTrue(real.contains("Data in ~/Library/Application Support/PsyNeuView; settings under com.psyneuview.macapp"))

        let test = VersionReport.aboutLines(
            appVersion: "0.5.19", appBuild: "0.5.19", psyNeuViewVersion: "0.5.10", checkoutPath: nil,
            psyNeuLinkVersion: nil, psyNeuLinkSource: nil, availableSources: [],
            identity: .test, buildCommit: "abc1234",
            bundlePath: "~/Desktop/PsyNeuView Test.app",
            dataFolder: "~/Library/Application Support/PsyNeuView-Test")
        XCTAssertEqual(test[0], "PsyNeuView Test app 0.5.19, built from commit abc1234 — a test build (com.psyneuview.macapp.test)")
        XCTAssertTrue(test.contains("Running from ~/Desktop/PsyNeuView Test.app"))
        XCTAssertTrue(test.contains("Data in ~/Library/Application Support/PsyNeuView-Test; settings under com.psyneuview.macapp.test"))
    }

    /// Without a stamped commit or a bundle, About says nothing about them —
    /// `swift run` has neither, and an empty "built from commit" is worse
    /// than none.
    func testAboutLeavesOutWhatItDoesNotKnow() {
        let lines = VersionReport.aboutLines(
            appVersion: "0.5.19", appBuild: nil, psyNeuViewVersion: nil, checkoutPath: nil,
            psyNeuLinkVersion: nil, psyNeuLinkSource: nil, availableSources: [],
            identity: .release, buildCommit: "", bundlePath: nil, dataFolder: nil)
        XCTAssertEqual(lines[0], "PsyNeuView app 0.5.19")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Running from") || $0.hasPrefix("Data in") })
    }

    func testTheLaunchLogHeaderNamesTheApp() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(LaunchLog.header(appVersion: "0.5.19", date: date, identity: .test)
            .contains("PsyNeuView Test app 0.5.19 launched"))
        XCTAssertTrue(LaunchLog.header(appVersion: "0.5.19", date: date, identity: .release)
            .contains("PsyNeuView app 0.5.19 launched"))
    }
}
