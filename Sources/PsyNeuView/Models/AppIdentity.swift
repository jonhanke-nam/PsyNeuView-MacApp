import Foundation

/// Which PsyNeuView app this is: the real one, or the test copy that runs
/// beside it (#209).
///
/// A test build used to carry the real app's identity — same bundle id, same
/// name, same icon, same preferences domain, same Application Support folder,
/// same `~/.psynewview.json`. The two could not run at once, a test wrote the
/// tester's real settings, and nothing on screen said which was which. On
/// 2026-10-07 three forgotten servers were still running and nobody could
/// tell them apart.
///
/// Everything that depends on "which app am I" is derived here, from the
/// bundle identifier alone, and nowhere else: names, folders, the backend's
/// environment, whether Sparkle runs. Pure, so a test can hold both
/// identities side by side and prove they never share a path.
///
/// `make test-app` builds "PsyNeuView Test.app" with the test bundle id; the
/// code is the same binary. Nothing else marks a build as a test build.
struct AppIdentity: Equatable, Hashable, Sendable {

    /// What kind of copy this is. The raw value is what the backend is told
    /// in `PSYNEUVIEW_APP_FLAVOR`.
    enum Flavor: String, Sendable {
        case release
        case test
    }

    let flavor: Flavor

    static let releaseBundleID = "com.psyneuview.macapp"
    static let testBundleID = "com.psyneuview.macapp.test"

    static let release = AppIdentity(flavor: .release)
    static let test = AppIdentity(flavor: .test)

    /// The identity of the running app, from its bundle id.
    ///
    /// Anything that is not the test bundle id is the real app: `swift run`
    /// has no bundle at all, and the release app must keep its paths exactly
    /// as they were before test builds existed.
    static func from(bundleIdentifier: String?) -> AppIdentity {
        bundleIdentifier == testBundleID ? .test : .release
    }

    static let current = from(bundleIdentifier: Bundle.main.bundleIdentifier)

    var isTest: Bool { flavor == .test }

    // MARK: Names

    /// `com.psyneuview.macapp` or `com.psyneuview.macapp.test`. The
    /// preferences domain follows from it: `UserDefaults.standard` is keyed
    /// by the bundle id, so the two apps never read each other's settings
    /// without any code for it.
    var bundleIdentifier: String {
        isTest ? Self.testBundleID : Self.releaseBundleID
    }

    /// "PsyNeuView" or "PsyNeuView Test": the app's name in the Dock, menus
    /// and window titles.
    var displayName: String {
        isTest ? "PsyNeuView Test" : "PsyNeuView"
    }

    /// "PsyNeuView" or "PsyNeuView-Test": the name of every folder the app
    /// owns (Application Support, Logs).
    var folderName: String {
        isTest ? "PsyNeuView-Test" : "PsyNeuView"
    }

    /// The main window's title: "PsyNeuView" for the real app, as it always
    /// was; "PsyNeuView Test 0.5.19" for the test app, so a glance at the
    /// window says which copy and which build this is.
    func windowTitle(version: String?) -> String {
        guard isTest else { return displayName }
        guard let version, !version.isEmpty else { return displayName }
        return "\(displayName) \(version)"
    }

    /// Keychain service for the app's GitHub grant. Per identity, so a test
    /// app authorised for a test never writes the real app's credential.
    var keychainService: String {
        "\(bundleIdentifier).github-token"
    }

    // MARK: Folders

    /// `~/Library/Application Support/PsyNeuView[-Test]`: where the included
    /// PsyNeuView is unpacked and its Python environment built.
    func supportDirectory(applicationSupport: URL = Self.userApplicationSupport) -> URL {
        applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// `~/Library/Logs/PsyNeuView[-Test]`: the launch logs (#208).
    func logsDirectory(library: URL = Self.userLibrary) -> URL {
        library.appendingPathComponent("Logs/\(folderName)", isDirectory: true)
    }

    /// `~/.psyneuview` or `~/.psyneuview-test`: the hidden folder the backend
    /// keeps its state in — PsyNeuLink clones, working copies of included
    /// models, layouts for read-only files, rescued models.
    ///
    /// For the real app this is PsyNeuView's own default and the app never
    /// names it to the backend. For the test app every one of those folders
    /// is passed explicitly (`backendOverrides`), under this root.
    func stateDirectory(home: URL = Self.userHome) -> URL {
        home.appendingPathComponent(isTest ? ".psyneuview-test" : ".psyneuview", isDirectory: true)
    }

    /// PsyNeuView's settings file. `~/.psynewview.json` for the real app
    /// (the backend's own default, spelling included); inside the test
    /// app's state folder for the test app.
    func configFile(home: URL = Self.userHome) -> URL {
        isTest
            ? stateDirectory(home: home).appendingPathComponent("psynewview.json")
            : home.appendingPathComponent(".psynewview.json")
    }

    /// Where the backend keeps its managed PsyNeuLink clones.
    func cloneRoot(home: URL = Self.userHome) -> URL {
        stateDirectory(home: home).appendingPathComponent("sources", isDirectory: true)
    }

    /// Where edited copies of included models go (PsyNeuView-archive#1319).
    func workingCopiesDirectory(home: URL = Self.userHome) -> URL {
        stateDirectory(home: home).appendingPathComponent("working-copies", isDirectory: true)
    }

    /// Layouts and labels for read-only PsyNeuLink files (PsyNeuView-archive#1321).
    func layoutsDirectory(home: URL = Self.userHome) -> URL {
        stateDirectory(home: home).appendingPathComponent("layouts", isDirectory: true)
    }

    /// The legacy models folder, where a rescue puts a user's own models
    /// (PsyNeuView-archive#1089).
    func userModelsDirectory(home: URL = Self.userHome) -> URL {
        stateDirectory(home: home).appendingPathComponent("models", isDirectory: true)
    }

    /// Where the Setup Wizard offers to put a PsyNeuView checkout.
    func defaultCheckoutDirectory(home: URL = Self.userHome) -> URL {
        home.appendingPathComponent("Documents/\(folderName)", isDirectory: true)
    }

    /// The project folder ("My Project Folder") a new install starts with
    /// (#240): `~/Documents/PsyNeuView-My-Models` for the real app,
    /// `~/Documents/PsyNeuView-Test-Models` for the test app.
    ///
    /// The real app's is PsyNeuView's own default (PsyNeuView-archive#1295), and the
    /// app never names it to the backend. The test app's is written into its
    /// own settings file before the backend starts (`projectFolderSeed`), so
    /// a test never creates or changes files in the real models folder.
    func defaultProjectFolder(home: URL = Self.userHome) -> URL {
        home.appendingPathComponent(
            isTest ? "Documents/PsyNeuView-Test-Models" : "Documents/PsyNeuView-My-Models",
            isDirectory: true)
    }

    /// Every folder and file this identity owns, for the collision test and
    /// for About.
    func ownedPaths(home: URL = Self.userHome, library: URL = Self.userLibrary,
                    applicationSupport: URL = Self.userApplicationSupport) -> [URL] {
        [
            supportDirectory(applicationSupport: applicationSupport),
            logsDirectory(library: library),
            stateDirectory(home: home),
            configFile(home: home),
            cloneRoot(home: home),
            workingCopiesDirectory(home: home),
            layoutsDirectory(home: home),
            userModelsDirectory(home: home),
            defaultCheckoutDirectory(home: home),
            defaultProjectFolder(home: home),
        ]
    }

    /// What to write to the test app's settings file so its project folder
    /// is its own (#240), and a line for the launch log; nil to leave the
    /// file as it is. Always nil for the real app.
    ///
    /// PsyNeuView has no way to change only its *default* project folder
    /// from outside: `PSYNEWVIEW_MODELS_DIR` fixes the folder outright — no
    /// Move…, no one-time offer (#212) — which would leave those untestable.
    /// The settings file's `model_dirs` is an ordinary choice, the same one
    /// Settings ▸ Folders ▸ Change… makes, so everything stays testable.
    ///
    /// Filled in when the file has no project folder yet, and pointed away
    /// when it names one of the real app's folders — the shared default or
    /// the hidden legacy one, which PsyNeuView would otherwise also adopt
    /// for the test app. Only the setting changes; no file is moved. A
    /// folder the tester chose anywhere else is left alone, and so is a file
    /// that isn't a JSON object.
    func projectFolderSeed(
        existing: Data?, home: URL = Self.userHome
    ) -> (settings: Data, note: String)? {
        guard isTest else { return nil }
        let own = defaultProjectFolder(home: home).path

        var settings: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: existing),
                  let dict = object as? [String: Any] else { return nil }
            settings = dict
        }

        let note: String
        var dirs = (settings["model_dirs"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let first = dirs.first {
            let expanded = first.hasPrefix("~/")
                ? home.appendingPathComponent(String(first.dropFirst(2))).path
                : first
            let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
            let realOnes = [AppIdentity.release.defaultProjectFolder(home: home),
                            AppIdentity.release.userModelsDirectory(home: home)]
                .map { $0.standardizedFileURL.path }
            guard realOnes.contains(resolved) else { return nil }
            dirs[0] = own
            note = "The test app's project folder was the real app's (\(first)); "
                + "it is now \(own). No files were moved."
        } else {
            dirs = [own]
            note = "The test app's project folder is \(own), its own (#240)."
        }
        settings["model_dirs"] = dirs

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return (data, note)
    }

    // MARK: The backend

    /// What the backend is told about the app that launched it.
    ///
    /// `PSYNEUVIEW_APP_FLAVOR` is set for both identities, so PsyNeuView can
    /// show a "Test build" badge when it learns to (#209; a PsyNeuView
    /// change). The path overrides are set only for the test app: the real
    /// app leaves PsyNeuView's defaults alone, exactly as before, so an
    /// existing install's settings, clones and working copies stay where
    /// they are.
    ///
    /// The models folder is deliberately not among them: `PSYNEWVIEW_MODELS_DIR`
    /// fixes the folder outright — no Move…, no one-time offer (#212) — which
    /// would make the test app unable to test those. The test app's project
    /// folder is set in its own settings file instead (`projectFolderSeed`,
    /// #240).
    func backendOverrides(home: URL = Self.userHome) -> [String: String] {
        var env = ["PSYNEUVIEW_APP_FLAVOR": flavor.rawValue]
        guard isTest else { return env }
        env["PSYNEUVIEW_CONFIG_FILE"] = configFile(home: home).path
        env["PSYNEUVIEW_CLONE_ROOT"] = cloneRoot(home: home).path
        env["PSYNEWVIEW_WORKING_DIR"] = workingCopiesDirectory(home: home).path
        env["PSYNEUVIEW_LAYOUTS_DIR"] = layoutsDirectory(home: home).path
        return env
    }

    // MARK: Updates

    /// Whether Sparkle runs at all. The test app never updates itself: its
    /// Info.plist has no feed, and an update would replace a test build with
    /// a release under the test name.
    var updatesEnabled: Bool { !isTest }

    // MARK: Where the user's folders are

    static var userHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var userLibrary: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? userHome.appendingPathComponent("Library")
    }

    static var userApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? userLibrary.appendingPathComponent("Application Support")
    }
}
