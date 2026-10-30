import XCTest
@testable import PsyNeuView

// Regression coverage for the app's pure, non-GUI logic (#44).
// XCTest (not Swift Testing) so it runs on the CI toolchain's Xcode.

final class BranchVisibilityTests: XCTestCase {
    let all = ["devel", "main", "feature/x", "fix/y"]

    func testDevModeShowsEverything() {
        XCTAssertEqual(Preferences.visibleBranches(all, developerMode: true, current: "devel"), all)
    }

    func testNonDevShowsOnlyTrunks() {
        XCTAssertEqual(Preferences.visibleBranches(all, developerMode: false, current: "devel"), ["devel", "main"])
    }

    func testCurrentBranchAlwaysVisibleSoYouCanSwitchAway() {
        let v = Preferences.visibleBranches(all, developerMode: false, current: "feature/x")
        XCTAssertTrue(v.contains("feature/x"))   // the branch you're on
        XCTAssertTrue(v.contains("devel"))       // + the trunks
        XCTAssertFalse(v.contains("fix/y"))      // but not other unstable branches
    }
}

final class PsyNeuLinkSourceTests: XCTestCase {
    func testPypiInstallArg() {
        XCTAssertEqual(PsyNeuLinkSource.pypi.pipInstallArgs(branch: "devel"), ["psyneulink"])
    }

    func testGithubDefaultRepo() {
        XCTAssertEqual(PsyNeuLinkSource.github.pipInstallArgs(branch: "devel"),
                       ["git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"])
    }

    func testGithubForkRepo() {
        XCTAssertEqual(PsyNeuLinkSource.github.pipInstallArgs(branch: "main", repo: "jonhanke-nam/PsyNeuLink"),
                       ["git+https://github.com/jonhanke-nam/PsyNeuLink.git@main"])
    }

    /// A local checkout installs editable and in place — two arguments, which
    /// is why these return a list rather than a single string. (#56)
    func testLocalInstallArgsAreEditable() {
        XCTAssertEqual(PsyNeuLinkSource.local.pipInstallArgs(branch: "", localPath: "/Users/me/PsyNeuLink"),
                       ["-e", "/Users/me/PsyNeuLink"])
    }

    func testLocalCheckoutValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Empty path is never valid.
        XCTAssertFalse(PsyNeuLinkSource.isValidLocalCheckout(""))
        // A bare directory is not a checkout.
        XCTAssertFalse(PsyNeuLinkSource.isValidLocalCheckout(root.path))

        // setup.py alone is not enough — plenty of Python projects have one.
        fm.createFile(atPath: root.appendingPathComponent("setup.py").path, contents: Data())
        XCTAssertFalse(PsyNeuLinkSource.isValidLocalCheckout(root.path))

        // With the package directory too, it looks like PsyNeuLink.
        try fm.createDirectory(at: root.appendingPathComponent("psyneulink"), withIntermediateDirectories: true)
        XCTAssertTrue(PsyNeuLinkSource.isValidLocalCheckout(root.path))

        // A *file* named psyneulink must not satisfy the directory check.
        let fileRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: fileRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fileRoot) }
        fm.createFile(atPath: fileRoot.appendingPathComponent("setup.py").path, contents: Data())
        fm.createFile(atPath: fileRoot.appendingPathComponent("psyneulink").path, contents: Data())
        XCTAssertFalse(PsyNeuLinkSource.isValidLocalCheckout(fileRoot.path))
    }

    func testRepoValidation() {
        XCTAssertTrue(PsyNeuLinkSource.isValidRepo(""))            // empty = use default
        XCTAssertTrue(PsyNeuLinkSource.isValidRepo("owner/repo"))
        XCTAssertFalse(PsyNeuLinkSource.isValidRepo("nobody"))     // no slash
        XCTAssertFalse(PsyNeuLinkSource.isValidRepo("a/b/c"))      // too many segments
    }

    func testStableBranches() {
        XCTAssertTrue(PsyNeuLinkSource.isStable("devel"))
        XCTAssertTrue(PsyNeuLinkSource.isStable("master"))
        XCTAssertFalse(PsyNeuLinkSource.isStable("feature/x"))
    }
}

final class VersionCompareTests: XCTestCase {
    func testAtLeastWhenEqualOrGreater() {
        XCTAssertTrue(SemanticVersion.isAtLeast("3.12", minimum: "3.12"))
        XCTAssertTrue(SemanticVersion.isAtLeast("3.13", minimum: "3.12"))
        XCTAssertTrue(SemanticVersion.isAtLeast("3.12.4", minimum: "3.9"))
        XCTAssertTrue(SemanticVersion.isAtLeast("22.1.0", minimum: "18.0"))
    }

    func testNotAtLeastWhenLower() {
        XCTAssertFalse(SemanticVersion.isAtLeast("3.8", minimum: "3.9"))
        XCTAssertFalse(SemanticVersion.isAtLeast("16.0", minimum: "18.0"))
    }
}

final class EnvironmentTests: XCTestCase {
    func testFindFreePortReturnsAUsablePort() {
        let port = PortChecker.findFreePort()
        XCTAssertGreaterThan(port, 0)
        XCTAssertLessThanOrEqual(port, 65535)
    }

    func testToolchainPathIsNonEmpty() {
        XCTAssertFalse(Shell.toolchainPath().isEmpty)
    }
}

/// The app must resolve tools from its own bundle and a fixed set of well-known
/// locations — never from the user's shell, whose PATH may put a conda or pyenv
/// interpreter ahead of everything else. (#60, under #26.)
final class ToolchainPathTests: XCTestCase {
    func testBundledToolsComeBeforeHomebrewAndSystem() {
        let path = Shell.composePath(bundled: ["/App.app/Contents/Resources/python-3.14.2/bin"])
        let dirs = path.split(separator: ":").map(String.init)
        XCTAssertEqual(dirs.first, "/App.app/Contents/Resources/python-3.14.2/bin")
        XCTAssertLessThan(dirs.firstIndex(of: "/opt/homebrew/bin")!, dirs.firstIndex(of: "/usr/bin")!)
    }

    func testSystemDirectoriesComeLast() {
        let dirs = Shell.composePath(bundled: []).split(separator: ":").map(String.init)
        XCTAssertEqual(Array(dirs.suffix(Shell.systemBinDirs.count)), Shell.systemBinDirs)
    }

    func testDuplicateDirectoriesAreCollapsed() {
        let dirs = Shell.composePath(bundled: ["/usr/bin", "/opt/homebrew/bin"])
            .split(separator: ":").map(String.init)
        XCTAssertEqual(dirs.count, Set(dirs).count)
        // A directory named in `bundled` keeps its earlier position.
        XCTAssertEqual(dirs.first, "/usr/bin")
    }

    /// The regression guard for #60: no matter what the developer has installed,
    /// the composed PATH never reaches into a version manager's shims.
    func testComposedPathNeverIncludesVersionManagerShims() {
        let path = Shell.toolchainPath()
        for shim in ["/.pyenv/", "/miniconda", "/anaconda", "/.nvm/", "/.asdf/", "/.rbenv/"] {
            XCTAssertFalse(path.contains(shim), "toolchain PATH leaked \(shim): \(path)")
        }
    }

    func testToolchainPathContainsTheSystemBinaries() {
        let dirs = Shell.toolchainPath().split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.contains("/usr/bin"))
        XCTAssertTrue(dirs.contains("/bin"))
    }
}

/// The supported-Python range, mirroring backend/pyproject.toml's
/// `requires-python = ">=3.12,<3.15"`. Before #61 the app accepted anything
/// >= 3.9, so 3.9–3.11 passed here and failed much later at `pip install -e .`.
final class PythonRequirementTests: XCTestCase {
    func testSupportedVersionsAreAccepted() {
        for version in ["3.12", "3.12.0", "3.13.2", "3.14", "3.14.11"] {
            XCTAssertTrue(PythonRequirement.isSupported(version), "expected \(version) supported")
        }
    }

    /// The regression guard for #61.
    func testVersionsBelowTheFloorAreRejected() {
        for version in ["3.9", "3.9.6", "3.10.14", "3.11.9"] {
            XCTAssertFalse(PythonRequirement.isSupported(version), "expected \(version) rejected")
        }
    }

    func testVersionsAtOrAboveTheCeilingAreRejected() {
        for version in ["3.15", "3.15.0", "3.16.1", "4.0"] {
            XCTAssertFalse(PythonRequirement.isSupported(version), "expected \(version) rejected")
        }
    }

    /// A 3.15 alpha is still 3.15 — it must not sneak under the exclusive bound.
    func testPrereleaseOfAnUnsupportedVersionIsRejected() {
        XCTAssertFalse(PythonRequirement.isSupported("3.15.0a1"))
    }

    func testRangeMatchesThePyprojectDeclaration() {
        XCTAssertEqual(PythonRequirement.minimumInclusive, "3.12")
        XCTAssertEqual(PythonRequirement.maximumExclusive, "3.15")
    }

    func testSupportedVersionsReadAsAList() {
        XCTAssertEqual(PythonRequirement.supportedVersionsDescription, "3.12, 3.13, or 3.14")
    }

    /// Every formula we would install must itself satisfy the range, and the one
    /// we prefer must be among them.
    func testFormulaeAreInsideTheSupportedRange() {
        for formula in PythonRequirement.supportedFormulae {
            let version = String(formula.split(separator: "@").last!)
            XCTAssertTrue(PythonRequirement.isSupported(version), "formula \(formula) is out of range")
        }
        XCTAssertTrue(PythonRequirement.supportedFormulae.contains(PythonRequirement.preferredFormula))
    }

    func testRejectionMessageNamesAnAlternativeWhenOneExists() {
        let message = PythonRequirement.rejectionMessage(
            found: "3.11.9",
            alternative: "/opt/homebrew/bin/python3.14"
        )
        XCTAssertTrue(message.contains("3.11.9"))
        XCTAssertTrue(message.contains("3.12, 3.13, or 3.14"))
        XCTAssertTrue(message.contains("/opt/homebrew/bin/python3.14"))
    }

    func testRejectionMessageOffersAnInstallWhenNoAlternativeExists() {
        let message = PythonRequirement.rejectionMessage(found: "3.11.9", alternative: nil)
        XCTAssertTrue(message.contains(PythonRequirement.preferredFormula))
    }
}

final class SemanticVersionTests: XCTestCase {
    func testComparesComponentwise() {
        XCTAssertTrue(SemanticVersion.isAtLeast("3.14.1", minimum: "3.14"))
        XCTAssertTrue(SemanticVersion.isAtLeast("3.14", minimum: "3.14.0"))
        XCTAssertFalse(SemanticVersion.isAtLeast("3.9", minimum: "3.12"))
        XCTAssertTrue(SemanticVersion.isAtLeast("3.100", minimum: "3.99"))
    }

    func testStopsAtNonNumericComponents() {
        XCTAssertTrue(SemanticVersion.isAtLeast("3.15.0a1", minimum: "3.15"))
        XCTAssertFalse(SemanticVersion.isBelow("3.15.0a1", exclusiveBound: "3.15"))
    }
}

/// The installer must never mutate a shared package prefix.
///
/// `ensurePythonLinked()` used to run `brew link --overwrite --force`, which
/// overwrites symlinks in the Homebrew prefix and can change what `python3`
/// means for every other project on the machine. Venv creation now takes the
/// interpreter's absolute path instead, so nothing needs linking. This scans the
/// real source tree so the call cannot quietly return. (#62, under #26)
final class PrefixMutationGuardTests: XCTestCase {
    /// Package root, derived from this file's location.
    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/PsyNeuViewTests/CoreLogicTests.swift
            .deletingLastPathComponent()          // .../Tests/PsyNeuViewTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("Sources")
    }

    private func swiftSources() throws -> [(url: URL, text: String)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return try walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { (url: $0, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testSourcesExistToScan() throws {
        XCTAssertFalse(try swiftSources().isEmpty, "found no Swift sources at \(sourcesDirectory.path)")
    }

    func testNoSourceInvokesBrewLink() throws {
        for (url, text) in try swiftSources() {
            XCTAssertFalse(
                text.contains("\"link\""),
                "\(url.lastPathComponent) passes \"link\" to a subprocess — brew link must not return (#62)"
            )
            XCTAssertFalse(
                text.contains("\"--overwrite\""),
                "\(url.lastPathComponent) passes \"--overwrite\" — this mutates a shared prefix (#62)"
            )
        }
    }
}

/// GitHub App device flow, run natively instead of shelling out to `gh`.
/// (#63, under #26)
final class GitHubDeviceFlowTests: XCTestCase {
    private func json(_ raw: String) -> Data { Data(raw.utf8) }
    /// Fixed instant so expiry maths is deterministic.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Device code

    func testParsesADeviceCodeResponse() throws {
        let code = try GitHubDeviceFlow.parseDeviceCode(json("""
        {"device_code":"abc123","user_code":"WDJB-MJHT",
         "verification_uri":"https://github.com/login/device",
         "expires_in":899,"interval":5}
        """))
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        XCTAssertEqual(code.deviceCode, "abc123")
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(code.expiresIn, 899)
    }

    func testMissingFieldsAreRejected() {
        XCTAssertThrowsError(try GitHubDeviceFlow.parseDeviceCode(json(#"{"user_code":"U"}"#)))
        XCTAssertThrowsError(try GitHubDeviceFlow.parseDeviceCode(json("not json")))
    }

    // MARK: Grants

    func testGrantCarriesBothExpiriesAsAbsoluteInstants() {
        let grant = GitHubDeviceFlow.parseGrant([
            "access_token": "ghu_token",
            "expires_in": 28800,
            "refresh_token": "ghr_refresh",
            "refresh_token_expires_in": 15_897_600,
        ], now: t0)
        XCTAssertEqual(grant?.accessToken, "ghu_token")
        XCTAssertEqual(grant?.expiresAt, t0.addingTimeInterval(28800))
        XCTAssertEqual(grant?.refreshToken, "ghr_refresh")
        XCTAssertEqual(grant?.refreshTokenExpiresAt, t0.addingTimeInterval(15_897_600))
    }

    /// An app with token expiry switched off sends no `expires_in` and no
    /// refresh token. That must read as long-lived, not as already expired.
    func testGrantWithoutExpiryIsTreatedAsLongLived() {
        let grant = GitHubDeviceFlow.parseGrant(["access_token": "ghu_token"], now: t0)
        XCTAssertNotNil(grant)
        XCTAssertNil(grant?.refreshToken)
        XCTAssertTrue(grant?.isFresh(at: t0) ?? false)
        XCTAssertFalse(grant?.canRefresh(at: t0) ?? true)
    }

    func testGrantIsStaleOnceInsideTheRefreshSkew() {
        let grant = GitHubDeviceFlow.parseGrant([
            "access_token": "ghu_token", "expires_in": 28800, "refresh_token": "ghr_r",
        ], now: t0)!
        XCTAssertTrue(grant.isFresh(at: t0))
        XCTAssertTrue(grant.isFresh(at: t0.addingTimeInterval(28800 - 600)))
        // Within the 5-minute skew, treat it as needing renewal already.
        XCTAssertFalse(grant.isFresh(at: t0.addingTimeInterval(28800 - 60)))
        XCTAssertFalse(grant.isFresh(at: t0.addingTimeInterval(28801)))
    }

    func testExpiredRefreshTokenCannotRefresh() {
        let grant = GitHubDeviceFlow.parseGrant([
            "access_token": "ghu_token", "expires_in": 28800,
            "refresh_token": "ghr_r", "refresh_token_expires_in": 1000,
        ], now: t0)!
        XCTAssertTrue(grant.canRefresh(at: t0))
        XCTAssertFalse(grant.canRefresh(at: t0.addingTimeInterval(1001)))
    }

    func testGrantSurvivesAKeychainRoundTrip() throws {
        let grant = GitHubDeviceFlow.parseGrant([
            "access_token": "ghu_token", "expires_in": 28800, "refresh_token": "ghr_r",
        ], now: t0)!
        let decoded = try JSONDecoder().decode(
            GitHubDeviceFlow.TokenGrant.self, from: JSONEncoder().encode(grant))
        XCTAssertEqual(decoded, grant)
    }

    // MARK: Polling

    func testAuthorizationPendingKeepsPolling() {
        XCTAssertEqual(
            GitHubDeviceFlow.parsePollOutcome(json(#"{"error":"authorization_pending"}"#), currentInterval: 5),
            .pending)
    }

    func testSlowDownBacksOff() {
        XCTAssertEqual(
            GitHubDeviceFlow.parsePollOutcome(json(#"{"error":"slow_down"}"#), currentInterval: 5),
            .slowDown(newInterval: 10))
        XCTAssertEqual(
            GitHubDeviceFlow.parsePollOutcome(json(#"{"error":"slow_down","interval":17}"#), currentInterval: 5),
            .slowDown(newInterval: 17))
    }

    func testAuthorizedResponseYieldsAGrant() {
        let outcome = GitHubDeviceFlow.parsePollOutcome(
            json(#"{"access_token":"ghu_token","expires_in":28800,"refresh_token":"ghr_r"}"#),
            currentInterval: 5, now: t0)
        guard case .authorized(let grant) = outcome else { return XCTFail("expected a grant") }
        XCTAssertEqual(grant.accessToken, "ghu_token")
    }

    func testTerminalErrorsStopTheFlow() {
        for code in ["expired_token", "access_denied", "incorrect_device_code",
                     "device_flow_disabled", "incorrect_client_credentials",
                     "unsupported_grant_type"] {
            guard case .failed = GitHubDeviceFlow.parsePollOutcome(
                json(#"{"error":"\#(code)"}"#), currentInterval: 5) else {
                return XCTFail("\(code) should be terminal")
            }
        }
    }

    /// The likeliest misconfiguration deserves a message that names the fix.
    func testDeviceFlowDisabledSaysHowToFixIt() {
        let message = GitHubDeviceFlow.describe(error: "device_flow_disabled", description: nil)
        XCTAssertTrue(message.contains("Enable it"))
    }

    func testAnEmptyBodyIsAFailureNotASuccess() {
        guard case .failed = GitHubDeviceFlow.parsePollOutcome(json("{}"), currentInterval: 5) else {
            return XCTFail("an empty body must not read as authorised")
        }
    }

    /// Tokens must be pinned to PsyNeuView, not to everything the user can reach.
    func testTokensAreRestrictedToTheRepository() {
        XCTAssertEqual(GitHubDeviceFlow.repositoryID, "1204522752")
    }

    /// A build that ships without a client ID cannot sign anyone in.
    func testClientIDIsConfigured() {
        XCTAssertFalse(GitHubDeviceFlow.clientID.isEmpty)
        XCTAssertTrue(GitHubDeviceFlow.clientID.hasPrefix("Iv23li"),
                      "expected a GitHub App client ID, not an App ID or OAuth ID")
    }

    /// The device flow exists so no secret ships in the binary. Guard that.
    func testNoClientSecretIsShipped() {
        let source = (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/PsyNeuView/Services/GitHubDeviceFlow.swift"),
            encoding: .utf8)) ?? ""
        XCTAssertFalse(source.isEmpty, "could not read GitHubDeviceFlow.swift")
        // The quoted form is what a request field looks like; the bare word also
        // appears in prose explaining why we don't send one.
        XCTAssertFalse(source.contains("\"client_secret\""),
                       "a client secret must never ship in the app binary (#63)")
    }
}

final class GitHubCredentialTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func grant(expiresIn: TimeInterval, refresh: String?, refreshExpiresIn: TimeInterval?)
        -> GitHubDeviceFlow.TokenGrant {
        GitHubDeviceFlow.TokenGrant(
            accessToken: "ghu_token",
            expiresAt: t0.addingTimeInterval(expiresIn),
            refreshToken: refresh,
            refreshTokenExpiresAt: refreshExpiresIn.map { t0.addingTimeInterval($0) })
    }

    func testNoStoredGrantMeansAuthorize() {
        XCTAssertEqual(GitHubCredential.disposition(of: nil, at: t0), .needsAuthorization)
    }

    func testFreshGrantIsUsedDirectly() {
        let g = grant(expiresIn: 28800, refresh: "ghr_r", refreshExpiresIn: 15_897_600)
        XCTAssertEqual(GitHubCredential.disposition(of: g, at: t0), .usable("ghu_token"))
    }

    func testLapsedGrantRefreshes() {
        let g = grant(expiresIn: 28800, refresh: "ghr_r", refreshExpiresIn: 15_897_600)
        XCTAssertEqual(
            GitHubCredential.disposition(of: g, at: t0.addingTimeInterval(29000)),
            .needsRefresh(refreshToken: "ghr_r"))
    }

    /// Both tokens dead — the user has to authorise again rather than the app
    /// looping on a refresh that can't succeed.
    func testExpiredRefreshTokenFallsBackToAuthorization() {
        let g = grant(expiresIn: 28800, refresh: "ghr_r", refreshExpiresIn: 40000)
        XCTAssertEqual(
            GitHubCredential.disposition(of: g, at: t0.addingTimeInterval(50000)),
            .needsAuthorization)
    }

    func testLapsedGrantWithNoRefreshTokenFallsBackToAuthorization() {
        let g = grant(expiresIn: 28800, refresh: nil, refreshExpiresIn: nil)
        XCTAssertEqual(
            GitHubCredential.disposition(of: g, at: t0.addingTimeInterval(29000)),
            .needsAuthorization)
    }

    /// The token goes in a git *header*, not the remote URL, so it is never
    /// written into the cloned repo's .git/config.
    func testAuthConfigIsAnExtraHeaderNotAURL() {
        let config = GitHubCredential.gitAuthConfig(token: "ghu_secret")
        XCTAssertTrue(config.hasPrefix("http.extraHeader=Authorization: Basic "))
        XCTAssertFalse(config.contains("https://"))
        XCTAssertFalse(config.contains("ghu_secret"))
        XCTAssertTrue(config.contains(Data("x-access-token:ghu_secret".utf8).base64EncodedString()))
    }

    func testRedactionHidesBothTheTokenAndItsEncodedForm() {
        let token = "ghu_secret"
        let encoded = Data("x-access-token:\(token)".utf8).base64EncodedString()
        let safe = GitHubCredential.redact("using \(token) header Basic \(encoded)", token: token)
        XCTAssertFalse(safe.contains(token))
        XCTAssertFalse(safe.contains(encoded))
    }

    func testKeychainServiceIsOurOwn() {
        XCTAssertTrue(GitHubCredential.service.hasPrefix("com.psyneuview"))
    }
}

/// The bundled runtime and the Swift version gate are configured in two
/// different files. If they drift, the app ships an interpreter it will then
/// refuse at runtime — so assert they agree. (#64, under #26)
final class BundledRuntimeTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PsyNeuViewTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    /// Parse `PYTHON_VERSION="3.14.7"` out of the shell config the build reads.
    private func pinnedPythonVersion() throws -> String {
        let conf = try String(
            contentsOf: packageRoot.appendingPathComponent("scripts/python-runtime.conf"),
            encoding: .utf8)
        for line in conf.split(separator: "\n") where line.hasPrefix("PYTHON_VERSION=") {
            return line
                .dropFirst("PYTHON_VERSION=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        throw XCTSkip("PYTHON_VERSION not found in scripts/python-runtime.conf")
    }

    func testPinnedRuntimeSatisfiesTheSupportedRange() throws {
        let pinned = try pinnedPythonVersion()
        XCTAssertTrue(PythonRequirement.isSupported(pinned),
                      "bundled Python \(pinned) is outside \(PythonRequirement.supportedVersionsDescription) "
                      + "— scripts/python-runtime.conf and PythonRequirement disagree")
    }

    func testRuntimeIsPinnedByChecksum() throws {
        let conf = try String(
            contentsOf: packageRoot.appendingPathComponent("scripts/python-runtime.conf"),
            encoding: .utf8)
        XCTAssertTrue(conf.contains("PBS_SHA256="), "the runtime download must be checksum-pinned")
        // A 64-character hex digest, not an empty placeholder.
        let digest = conf.split(separator: "\n")
            .first { $0.hasPrefix("PBS_SHA256=") }?
            .dropFirst("PBS_SHA256=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
        XCTAssertEqual(digest.count, 64, "expected a sha256 digest, got \(digest.count) characters")
    }

    /// Outside an app bundle there is no runtime; the lookup must return nil
    /// rather than trapping.
    func testBundledPythonLookupIsSafeWithoutABundle() {
        _ = Shell.bundledPythonPath()
    }
}

/// A venv records the absolute path of its base interpreter and can't outlive
/// it. With the runtime inside a version-stamped bundle directory (#64), a
/// Sparkle update that bumps Python moves that path and orphans every venv.
/// (#66, under #26)
final class VenvHealthTests: XCTestCase {
    /// The real format, as written by `python3 -m venv` from the bundled runtime.
    private let realConfig = """
    home = /Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin
    include-system-site-packages = false
    version = 3.14.7
    executable = /Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin/python3.14
    command = /Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin/python3 -m venv
    """

    func testParsesARealPyvenvConfig() {
        let record = VenvRecord.parse(realConfig)
        XCTAssertEqual(record?.home,
                       "/Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin")
        XCTAssertEqual(record?.version, "3.14.7")
    }

    func testConfigWithoutHomeIsNotARecord() {
        XCTAssertNil(VenvRecord.parse("version = 3.14.7"))
        XCTAssertNil(VenvRecord.parse(""))
    }

    func testNoVenvIsAbsent() {
        XCTAssertEqual(
            VenvHealth.disposition(record: nil, currentInterpreterBin: "/x/bin", recordedHomeExists: false),
            .absent)
    }

    func testMatchingInterpreterIsUsable() {
        let record = VenvRecord.parse(realConfig)
        XCTAssertEqual(
            VenvHealth.disposition(
                record: record,
                currentInterpreterBin: "/Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin",
                recordedHomeExists: true),
            .usable)
    }

    /// The case this issue exists for: Sparkle ships 3.14.8, the runtime
    /// directory is renamed, and the old venv points at a path that is gone.
    func testPatchBumpTriggersARebuild() {
        let record = VenvRecord.parse(realConfig)
        let disposition = VenvHealth.disposition(
            record: record,
            currentInterpreterBin: "/Applications/PsyNeuView.app/Contents/Resources/python-3.14.8/bin",
            recordedHomeExists: false)
        guard case .rebuild(let reason) = disposition else {
            return XCTFail("expected a rebuild, got \(disposition)")
        }
        XCTAssertTrue(reason.contains("3.14.7"), reason)
        XCTAssertTrue(reason.contains("3.14.8"), reason)
    }

    /// Same recorded path, but the interpreter behind it vanished — an app
    /// bundle replaced in place.
    func testSamePathWithMissingInterpreterRebuilds() {
        let record = VenvRecord.parse(realConfig)
        guard case .rebuild = VenvHealth.disposition(
            record: record,
            currentInterpreterBin: "/Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin",
            recordedHomeExists: false) else {
            return XCTFail("a missing interpreter must force a rebuild")
        }
    }

    /// No bundled runtime resolved: judge the venv on its own interpreter rather
    /// than rebuilding a perfectly good environment.
    func testWithoutACurrentInterpreterAnIntactVenvSurvives() {
        let record = VenvRecord.parse(realConfig)
        XCTAssertEqual(
            VenvHealth.disposition(record: record, currentInterpreterBin: nil, recordedHomeExists: true),
            .usable)
        guard case .rebuild = VenvHealth.disposition(
            record: record, currentInterpreterBin: nil, recordedHomeExists: false) else {
            return XCTFail("a vanished interpreter must force a rebuild")
        }
    }

    func testTrailingSlashesDoNotReadAsADifferentPath() {
        let record = VenvRecord(home: "/Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin/", version: nil)
        XCTAssertEqual(
            VenvHealth.disposition(
                record: record,
                currentInterpreterBin: "/Applications/PsyNeuView.app/Contents/Resources/python-3.14.7/bin",
                recordedHomeExists: true),
            .usable)
    }

    func testBinDirectoryOfInterpreter() {
        XCTAssertEqual(
            VenvHealth.binDirectory(ofInterpreter: "/App/Contents/Resources/python-3.14.7/bin/python3"),
            "/App/Contents/Resources/python-3.14.7/bin")
    }

    func testApplicationsDetection() {
        XCTAssertTrue(VenvHealth.isRunningFromApplications(bundlePath: "/Applications/PsyNeuView.app"))
        XCTAssertFalse(VenvHealth.isRunningFromApplications(bundlePath: "/Users/me/Downloads/PsyNeuView.app"))
        XCTAssertFalse(VenvHealth.isRunningFromApplications(bundlePath: "/Volumes/PsyNeuView/PsyNeuView.app"))
    }
}

/// PsyNeuView ships inside the app rather than being cloned, which is what
/// removes the collaborator-access gate entirely. (#74, under #26)
final class BundledPsyNeuViewTests: XCTestCase {
    /// The naming contract with scripts/fetch-psyneuview.sh. If either side
    /// changes the shape, the app silently stops finding its own payload.
    func testVersionIsReadFromTheArchiveName() {
        XCTAssertEqual(
            BundledPsyNeuView.version(fromArchiveName: "psyneuview-0.0.0-dev.463bd6f.tar.gz"),
            "0.0.0-dev.463bd6f")
        XCTAssertEqual(
            BundledPsyNeuView.version(fromArchiveName: "psyneuview-1.2.0.tar.gz"),
            "1.2.0")
        // A candidate keeps its tag's suffix, so each one unpacks afresh.
        XCTAssertEqual(
            BundledPsyNeuView.version(fromArchiveName: "psyneuview-0.6.9-rc4.tar.gz"),
            "0.6.9-rc4")
    }

    func testNonArchiveNamesAreRejected() {
        for name in ["psyneuview.tar.gz", "python-3.14.7.tar.gz",
                     "psyneuview-1.2.0.zip", "psyneuview-.tar.gz", ""] {
            XCTAssertNil(BundledPsyNeuView.version(fromArchiveName: name), name)
        }
    }

    func testInstallDirectoryIsVersionedUnderApplicationSupport() {
        let dir = BundledPsyNeuView.installDirectory(version: "1.2.0")
        XCTAssertEqual(dir.lastPathComponent, "psyneuview-1.2.0")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "PsyNeuView")
        XCTAssertTrue(dir.path.contains("Application Support"), dir.path)
    }

    /// A half-extracted tree — interrupted unpack, full disk — must not read as
    /// installed, or the app starts against a directory missing its backend.
    func testPartialExtractionIsNotUsable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        XCTAssertFalse(BundledPsyNeuView.isUsable(at: root), "a missing tree is not usable")

        try fm.createDirectory(at: root.appendingPathComponent("backend/app"),
                               withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("backend/app/main.py"),
                      atomically: true, encoding: .utf8)
        XCTAssertFalse(BundledPsyNeuView.isUsable(at: root),
                       "backend alone is not enough — the frontend must be there too")

        try fm.createDirectory(at: root.appendingPathComponent("frontend/dist"),
                               withIntermediateDirectories: true)
        try "<html></html>".write(to: root.appendingPathComponent("frontend/dist/index.html"),
                                  atomically: true, encoding: .utf8)
        XCTAssertTrue(BundledPsyNeuView.isUsable(at: root))
    }

    /// Outside an app bundle there is no archive; the lookup must return nil
    /// rather than trapping, so developer builds fall back to the clone.
    func testArchiveLookupIsSafeWithoutABundle() {
        _ = BundledPsyNeuView.archiveURL()
    }
}

/// The app must never install Homebrew.
///
/// Installing it means writing to /opt/homebrew — a prefix shared with
/// everything else on the machine — and it prompts for the user's password to do
/// so. Python and PsyNeuView now ship inside the app, so nothing needs it.
/// Where a developer build genuinely wants a tool we don't ship, the app says
/// what to install rather than installing it. (#67, under #26)
final class NoHomebrewInstallTests: XCTestCase {
    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftSources() throws -> [(name: String, text: String)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return try walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testSourcesExistToScan() throws {
        XCTAssertFalse(try swiftSources().isEmpty, "found no Swift sources at \(sourcesDirectory.path)")
    }

    /// The bootstrap script is the thing that actually mutates the machine.
    func testNoSourceRunsTheHomebrewInstaller() throws {
        for (name, text) in try swiftSources() {
            XCTAssertFalse(
                text.contains("Homebrew/install"),
                "\(name) runs the Homebrew bootstrap — the app must not install Homebrew (#67)")
            XCTAssertFalse(
                text.contains("func installHomebrew"),
                "\(name) still defines installHomebrew (#67)")
        }
    }

    /// Naming a formula in a message is fine — that's advice. Running the
    /// installer is not. Keep the distinction explicit so the guard above isn't
    /// mistaken for a ban on mentioning Homebrew at all.
    func testSuggestingAFormulaIsStillAllowed() {
        XCTAssertFalse(PythonRequirement.preferredFormula.isEmpty)
        XCTAssertTrue(PythonRequirement.preferredFormula.hasPrefix("python@"))
    }
}

/// Branch switching operates on a git checkout, so it is meaningless once
/// PsyNeuView ships inside the app. Its ⌘B shortcut also never worked, because
/// the menu item was created only in `menuNeedsUpdate` — a key equivalent can't
/// fire for an item that doesn't exist until the menu is first opened. (#75)
final class BranchSwitchingGateTests: XCTestCase {
    func testBundledInstallOffersNoBranchSwitching() {
        XCTAssertFalse(BundledPsyNeuView.offersBranchSwitching(
            useBundledApp: true, hasBundledArchive: true))
    }

    func testCloneInstallStillOffersIt() {
        XCTAssertTrue(BundledPsyNeuView.offersBranchSwitching(
            useBundledApp: false, hasBundledArchive: true),
            "opting out of the bundle means a checkout, which has branches")
    }

    /// A developer build that never ran `make psyneuview-bundle` has no archive,
    /// so it clones — and must still offer branch switching even though the
    /// preference defaults on.
    func testBuildWithoutAnArchiveStillOffersIt() {
        XCTAssertTrue(BundledPsyNeuView.offersBranchSwitching(
            useBundledApp: true, hasBundledArchive: false))
        XCTAssertTrue(BundledPsyNeuView.offersBranchSwitching(
            useBundledApp: false, hasBundledArchive: false))
    }
}

/// The app must not write into a user's working tree without being asked.
///
/// `patchBackendForStaticServing()` used to append a StaticFiles mount to
/// `backend/app/main.py` in the checkout — editing tracked source and leaving an
/// uncommitted diff the user didn't make. Upstream now mounts the frontend
/// itself, so the patch is deleted rather than left as dead code that writes to
/// a source tree if its guard ever stops matching. (#69, under #26)
final class CheckoutWriteTests: XCTestCase {
    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    func testNoSourcePatchesTheBackend() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(sourcesDirectory.path)")
        }
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("patchBackendForStaticServing"),
                           "\(url.lastPathComponent) still patches the backend (#69)")
            XCTAssertFalse(text.contains("_frontend_dist"),
                           "\(url.lastPathComponent) still injects Python into the checkout (#69)")
        }
        XCTAssertGreaterThan(scanned, 0, "scanned no sources — the guard would pass vacuously")
    }

    /// A Makefile is what the installer keys on to decide it can adopt a folder.
    func testExistingCheckoutIsDetected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-adopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertFalse(BundledPsyNeuView.wouldAdoptExistingCheckout(at: root),
                       "an empty folder is a fresh install, not an adoption")

        try "all:".write(to: root.appendingPathComponent("Makefile"),
                         atomically: true, encoding: .utf8)
        XCTAssertTrue(BundledPsyNeuView.wouldAdoptExistingCheckout(at: root))
    }
}

/// A bundled install has no `.git`, so anything that shells out to git against
/// it fails — on every launch, in the ⌘U handler, and in the self-check. Worse,
/// invoking `git` on a Mac with no Command Line Tools pops the "install
/// developer tools" dialog that #67 removed from setup. (#87, under #26)
final class UpdaterGitTrackingTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUnpackedBundleIsNotTracked() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // What BundledPsyNeuView.ensureUnpacked produces: sources, no .git.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("backend/app"), withIntermediateDirectories: true)
        XCTAssertFalse(Updater.tracksUpdatesWithGit(repoPath: dir),
                       "a bundled tree has no .git and must never be given to git")
    }

    func testCheckoutIsTracked() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertTrue(Updater.tracksUpdatesWithGit(repoPath: dir))
    }

    /// A worktree records .git as a *file* pointing at the real git dir, not a
    /// directory. Developers using worktrees must still get update checks.
    func testWorktreeCheckoutIsTracked() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "gitdir: /elsewhere/.git/worktrees/x"
            .write(to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertTrue(Updater.tracksUpdatesWithGit(repoPath: dir),
                      ".git as a file is a worktree, which git handles fine")
    }

    func testMissingDirectoryIsNotTracked() {
        XCTAssertFalse(Updater.tracksUpdatesWithGit(
            repoPath: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
    }
}

/// 0.5.0 shipped unable to start from its own bundled tree: the launch check
/// looked for a Makefile, which a bundled tree deliberately doesn't ship — it
/// drives venv creation, npm and the dev servers, none of which a bundled
/// install uses. (#89, under #26)
final class RunnableTreeTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Exactly what fetch-psyneuview.sh stages: backend, built frontend, no Makefile.
    func testBundledTreeIsRunnable() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("backend/app"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("backend/app/main.py"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.appendingPathComponent("frontend/dist"), withIntermediateDirectories: true)
        try "<html>".write(to: dir.appendingPathComponent("frontend/dist/index.html"), atomically: true, encoding: .utf8)

        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("Makefile").path),
                       "a bundled tree must not need a Makefile")
        XCTAssertTrue(BundledPsyNeuView.isRunnableTree(at: dir),
                      "this is the shape 0.5.0 refused to start from")
    }

    /// A clone is runnable before it has been built — no dist/ yet.
    func testCloneIsRunnable() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "all:".write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        XCTAssertTrue(BundledPsyNeuView.isRunnableTree(at: dir))
    }

    func testUnrelatedDirectoryIsNot() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(BundledPsyNeuView.isRunnableTree(at: dir))
    }
}

/// The app's version no longer mirrors the PsyNeuView it bundles — 0.5.2 shipped
/// five launcher changes against zero PsyNeuView changes. So the bundled version
/// has to be recorded and readable, or "which PsyNeuView produced this
/// behaviour?" becomes unanswerable from a bug report.
/// (#57, jonhanke-nam/PsyNeuView-archive#1073)
final class BundledVersionStampTests: XCTestCase {
    private func makeTree(stamp: String?) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let stamp {
            try stamp.write(to: root.appendingPathComponent("BUNDLED_VERSION"),
                            atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Exactly what scripts/fetch-psyneuview.sh writes.
    func testReadsTheStampTheBundlerWrites() throws {
        let tree = try makeTree(stamp: "version=0.5.0\nref=v0.5.0\n")
        defer { try? FileManager.default.removeItem(at: tree) }
        XCTAssertEqual(BundledPsyNeuView.installedVersion(at: tree), "0.5.0")
    }

    func testHandlesADevPin() throws {
        let tree = try makeTree(stamp: "version=0.0.0-dev.463bd6f\nref=463bd6f\n")
        defer { try? FileManager.default.removeItem(at: tree) }
        XCTAssertEqual(BundledPsyNeuView.installedVersion(at: tree), "0.0.0-dev.463bd6f")
    }

    /// A clone has no stamp; the caller must get nil rather than a wrong answer.
    func testNoStampMeansUnknown() throws {
        let tree = try makeTree(stamp: nil)
        defer { try? FileManager.default.removeItem(at: tree) }
        XCTAssertNil(BundledPsyNeuView.installedVersion(at: tree))
    }

    /// #15: the release date fetch-psyneuview.sh writes beside the version.
    func testReadsTheReleaseDate() throws {
        let tree = try makeTree(stamp: "version=0.6.2\nref=v0.6.2\nrepo=jonhanke-nam/PsyNeuView\nreleased=2026-10-16T18:02:56Z\n")
        defer { try? FileManager.default.removeItem(at: tree) }
        XCTAssertEqual(BundledPsyNeuView.installedVersion(at: tree), "0.6.2")
        XCTAssertEqual(BundledPsyNeuView.installedReleaseDate(at: tree),
                       Date(timeIntervalSince1970: 1_792_173_776))
    }

    /// A stamp from before #15, or a failed lookup (`released=`), has no date.
    func testNoReleaseDateMeansNone() throws {
        for stamp in ["version=0.6.2\nref=v0.6.2\n", "version=0.6.2\nreleased=\n", "version=0.6.2\nreleased=soon\n"] {
            let tree = try makeTree(stamp: stamp)
            defer { try? FileManager.default.removeItem(at: tree) }
            XCTAssertNil(BundledPsyNeuView.installedReleaseDate(at: tree), "stamp: \(stamp.debugDescription)")
            XCTAssertEqual(BundledPsyNeuView.installedVersion(at: tree), "0.6.2")
        }
    }

    func testMalformedStampMeansUnknown() throws {
        for stamp in ["ref=v0.5.0\n", "version=\n", ""] {
            let tree = try makeTree(stamp: stamp)
            defer { try? FileManager.default.removeItem(at: tree) }
            XCTAssertNil(BundledPsyNeuView.installedVersion(at: tree), "stamp: \(stamp.debugDescription)")
        }
    }
}

/// Three versions move independently — the app, the bundled PsyNeuView, and the
/// PsyNeuLink installed at first run — so About has to report all three or a bug
/// report can't say what produced the behaviour.
/// (#57, jonhanke-nam/PsyNeuView-archive#1073)
final class VersionReportTests: XCTestCase {
    func testReadsAVersionFromADistInfoName() {
        XCTAssertEqual(
            VersionReport.version(fromDistInfo: "psyneulink-0.19.1.0+10.g83cc4165b7.dist-info",
                                  package: "psyneulink"),
            "0.19.1.0+10.g83cc4165b7",
            "a git-describe suffix is a normal PyPI version and must survive intact")
        XCTAssertEqual(
            VersionReport.version(fromDistInfo: "psyneulink-0.20.2.0.dist-info", package: "psyneulink"),
            "0.20.2.0")
    }

    /// Distribution names normalise `-` to `_` on disk.
    func testAcceptsTheNormalisedFormOnDisk() {
        XCTAssertEqual(
            VersionReport.version(fromDistInfo: "some_pkg-1.2.3.dist-info", package: "some-pkg"),
            "1.2.3")
    }

    func testIgnoresOtherPackages() {
        XCTAssertNil(VersionReport.version(fromDistInfo: "numpy-2.5.3.dist-info", package: "psyneulink"))
        XCTAssertNil(VersionReport.version(fromDistInfo: "psyneulink", package: "psyneulink"))
        XCTAssertNil(VersionReport.version(fromDistInfo: "psyneulink-.dist-info", package: "psyneulink"))
    }

    func testSourceNamesComeFromTheCloneDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-src-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for name in ["PsyNeuLink-PrincetonUniversity", "PsyNeuLink-jonhanke-nam", "unrelated"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertEqual(VersionReport.availablePsyNeuLinkSources(in: root),
                       ["PrincetonUniversity", "jonhanke-nam"].sorted())
    }

    func testAboutNamesAllThreeVersions() {
        let lines = VersionReport.aboutLines(
            appVersion: "0.5.2", appBuild: "0.5.2",
            psyNeuViewVersion: "0.5.0", checkoutPath: nil,
            psyNeuLinkVersion: "0.19.1.0", psyNeuLinkSource: "PyPI",
            availableSources: ["PrincetonUniversity"])
        XCTAssertEqual(lines[0], "PsyNeuView app 0.5.2")
        XCTAssertEqual(lines[1], "PsyNeuView 0.5.0, included with this app")
        XCTAssertEqual(lines[2], "PsyNeuLink 0.19.1.0, installed from PyPI")
        XCTAssertTrue(lines[3].contains("PrincetonUniversity"))
    }

    /// A build number only earns a line when it differs from the version.
    func testBuildNumberShownOnlyWhenItDiffers() {
        XCTAssertEqual(
            VersionReport.aboutLines(appVersion: "0.5.2", appBuild: "142",
                                     psyNeuViewVersion: nil, checkoutPath: nil,
                                     psyNeuLinkVersion: nil, psyNeuLinkSource: nil,
                                     availableSources: [])[0],
            "PsyNeuView app 0.5.2 (build 142)")
    }

    /// Before setup, and on the developer clone path, About must still say
    /// something true rather than showing a blank or a wrong version.
    func testHonestFallbacksBeforeAnythingIsInstalled() {
        let fresh = VersionReport.aboutLines(
            appVersion: "0.5.2", appBuild: nil,
            psyNeuViewVersion: nil, checkoutPath: nil,
            psyNeuLinkVersion: nil, psyNeuLinkSource: nil, availableSources: [])
        XCTAssertEqual(fresh[1], "PsyNeuView not installed yet")
        XCTAssertEqual(fresh[2], "PsyNeuLink not installed yet")

        let clone = VersionReport.aboutLines(
            appVersion: "0.5.2", appBuild: nil,
            psyNeuViewVersion: nil, checkoutPath: "/Users/x/PsyNeuView",
            psyNeuLinkVersion: "0.20.2.0", psyNeuLinkSource: "local checkout",
            availableSources: [])
        XCTAssertEqual(clone[1], "PsyNeuView from your checkout at /Users/x/PsyNeuView")
    }

    /// #195: a checkout names its branch too.
    func testACheckoutNamesItsBranch() {
        let lines = VersionReport.aboutLines(
            appVersion: "0.5.15", appBuild: nil,
            psyNeuViewVersion: nil, checkoutPath: "~/code/PsyNeuView", checkoutBranch: "devel",
            psyNeuLinkVersion: nil, psyNeuLinkSource: nil, availableSources: [])
        XCTAssertEqual(lines[1], "PsyNeuView from your checkout at ~/code/PsyNeuView, on branch devel")
    }
}

/// A 0.5.3 install declared startup failed at 30s while PsyNeuLink was still
/// warming up — it finished at 38.67s, eleven seconds after the app gave up, and
/// nothing was still watching. (#101)
final class StartupTimingTests: XCTestCase {
    /// The measured failure: 38.67s of warm-up against a 30s ceiling.
    func testCeilingExceedsAnObservedSlowStart() {
        let observedWarmUp: TimeInterval = 38.67
        XCTAssertGreaterThan(Constants.healthTimeout, observedWarmUp,
                             "the ceiling must exceed a start we have actually seen succeed")
        // And with real headroom: that machine was not pathological, and a colder
        // one will be slower.
        XCTAssertGreaterThan(Constants.healthTimeout, observedWarmUp * 4)
    }

    /// The user must be told something before the wait feels like a hang, and
    /// well before the app gives up.
    func testWarningComesLongBeforeTheCeiling() {
        XCTAssertLessThan(Constants.healthSlowAfter, Constants.healthTimeout)
        XCTAssertLessThan(Constants.healthSlowAfter, 30,
                          "silence past ~20s reads as a hang")
        XCTAssertGreaterThan(Constants.healthTimeout / Constants.healthSlowAfter, 5,
                             "warning should come early in the wait, not just before giving up")
    }

    func testPollIntervalIsFrequentEnoughToReportProgress() {
        XCTAssertLessThanOrEqual(Constants.healthPollInterval, 2)
        XCTAssertGreaterThan(Constants.healthPollInterval, 0)
    }
}

/// The startup sequence, as a sequence. Each case here is a bug that reached a
/// user today because nothing asserted it. (#104)
final class StartupSequenceTests: XCTestCase {

    /// #96: a finished install showed the debug log. Whatever else changes,
    /// starting must never resolve to "show the user internal messages".
    func testStartingAlwaysShowsAStatusNeverTheLog() {
        for elapsed in [0.0, 5.0, 19.0, 21.0, 60.0, 300.0] {
            guard case .showStarting = StartupSequence.action(for: .starting(elapsed: elapsed)) else {
                return XCTFail("elapsed \(elapsed) must show a status window")
            }
        }
    }

    /// #101: 38.67s of warm-up against a 30s ceiling was called a failure.
    /// A slow start is a slow start.
    func testASlowStartIsNotAFailure() {
        let action = StartupSequence.action(for: .starting(elapsed: 38.67))
        guard case .showStarting(let status) = action else {
            return XCTFail("38.67s is the warm-up we actually measured; it must not be a failure")
        }
        XCTAssertTrue(status.contains("38"), "the wait should be reported, not hidden: \(status)")
    }

    /// Silence reads as a hang, so the message must change once the wait is
    /// noticeable — and must not be alarming before then.
    func testReassuranceAppearsOnlyOnceTheWaitIsNoticeable() {
        guard case .showStarting(let early) = StartupSequence.action(for: .starting(elapsed: 3)),
              case .showStarting(let late) = StartupSequence.action(for: .starting(elapsed: 45))
        else { return XCTFail("both should be starting states") }
        XCTAssertNotEqual(early, late)
        XCTAssertFalse(early.contains("Still starting"), "3s is not worth remarking on")
        XCTAssertTrue(late.contains("Still starting"))
    }

    func testReadyOpensTheApp() {
        XCTAssertEqual(StartupSequence.action(for: .ready), .showAppWindow)
    }

    func testNothingInstalledOpensTheWizard() {
        XCTAssertEqual(StartupSequence.action(for: .notConfigured), .showSetupWizard)
    }

    /// #89: the tree moved or was deleted. The reason must name the path, since
    /// that is the only thing that makes it actionable.
    func testAMissingTreeNamesItsPath() {
        guard case .showFailure(let reason) =
                StartupSequence.action(for: .treeMissing(path: "/somewhere/psyneuview-0.5.0"))
        else { return XCTFail("a missing tree is a failure") }
        XCTAssertTrue(reason.contains("/somewhere/psyneuview-0.5.0"))
        XCTAssertTrue(reason.contains("Setup Wizard"), "it should say what to do about it")
    }

    /// #101: Try Again was offered while the server was already starting, where
    /// it could only log "Cannot start". A control that cannot act is worse than
    /// no control — the user clicked it four times.
    func testRetryIsOfferedOnlyWhenItCanAct() {
        XCTAssertFalse(StartupSequence.retryIsUseful(canStart: false))
        XCTAssertTrue(StartupSequence.retryIsUseful(canStart: true))
    }

    /// The reassurance threshold has to sit inside the window the app waits, or
    /// the user is told nothing before it gives up.
    func testThresholdsAreOrderedSensibly() {
        XCTAssertLessThan(Constants.healthSlowAfter, Constants.healthTimeout)
    }
}

/// A tree can be perfectly intact while its Python environment is missing. A
/// 0.5.2 user hit exactly that: the app found the tree, found no venv, logged
/// "run the Setup Wizard" and stopped — with the message in a log he had no
/// reason to open. (#106)
final class EnvironmentHealthTests: XCTestCase {
    private func makeTree(withVenv: Bool, pipOnly: Bool = false) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-env-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("backend/app"),
                               withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("backend/app/main.py"),
                      atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("frontend/dist"),
                               withIntermediateDirectories: true)
        try "<html>".write(to: root.appendingPathComponent("frontend/dist/index.html"),
                           atomically: true, encoding: .utf8)
        if withVenv || pipOnly {
            let bin = root.appendingPathComponent("backend/.venv/bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
            if !pipOnly {
                fm.createFile(atPath: bin.appendingPathComponent("python").path,
                              contents: Data("#!/bin/sh\n".utf8), attributes: attrs)
            }
            fm.createFile(atPath: bin.appendingPathComponent("pip").path,
                          contents: Data("#!/bin/sh\n".utf8), attributes: attrs)
        }
        return root
    }

    /// The exact shape reported: source present, environment absent.
    func testIntactTreeWithNoEnvironmentIsRunnableButNotReady() throws {
        let tree = try makeTree(withVenv: false)
        defer { try? FileManager.default.removeItem(at: tree) }
        XCTAssertTrue(BundledPsyNeuView.isRunnableTree(at: tree),
                      "the source is fine — this must not be mistaken for a broken install")
        XCTAssertFalse(BundledPsyNeuView.hasUsableEnvironment(at: tree),
                       "and the environment is missing, which is the thing to repair")
    }

    func testCompleteEnvironmentIsReady() throws {
        let tree = try makeTree(withVenv: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        XCTAssertTrue(BundledPsyNeuView.hasUsableEnvironment(at: tree))
    }

    /// A half-built venv — an install interrupted partway — must not read as
    /// ready, or the app starts against an environment that cannot run.
    func testHalfBuiltEnvironmentIsNotReady() throws {
        let tree = try makeTree(withVenv: false, pipOnly: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        XCTAssertFalse(BundledPsyNeuView.hasUsableEnvironment(at: tree))
    }

    func testMissingTreeIsNeitherRunnableNorReady() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertFalse(BundledPsyNeuView.isRunnableTree(at: nowhere))
        XCTAssertFalse(BundledPsyNeuView.hasUsableEnvironment(at: nowhere))
    }
}

/// A venv records its interpreter by absolute path, and that interpreter lives
/// inside the app bundle. Running from a DMG or Downloads and moving the app
/// later strands a 1.4 GB environment, surfacing days afterwards as a failure
/// with no visible connection to its cause. (#109)
final class AppRelocationTests: XCTestCase {

    func testApplicationsNeedsNoMove() {
        XCTAssertEqual(AppRelocation.classify(bundlePath: "/Applications/PsyNeuView.app"), .installed)
        XCTAssertEqual(AppRelocation.classify(bundlePath: "/System/Applications/PsyNeuView.app"), .installed)
        XCTAssertFalse(AppRelocation.classify(bundlePath: "/Applications/PsyNeuView.app").needsMoving)
    }

    /// The case we think stranded a developer's environment.
    func testMountedDiskImageIsRecognised() {
        let location = AppRelocation.classify(bundlePath: "/Volumes/PsyNeuView/PsyNeuView.app")
        XCTAssertEqual(location, .diskImage(path: "/Volumes/PsyNeuView/PsyNeuView.app"))
        XCTAssertTrue(location.needsMoving)
    }

    func testDownloadsAndDesktopAreRecognised() {
        for path in ["/Users/x/Downloads/PsyNeuView.app", "/Users/x/Desktop/PsyNeuView.app"] {
            XCTAssertEqual(AppRelocation.classify(bundlePath: path), .elsewhere(path: path))
            XCTAssertTrue(AppRelocation.classify(bundlePath: path).needsMoving)
        }
    }

    /// A trailing slash or a `.` segment is the same location.
    func testPathsAreNormalisedBeforeJudging() {
        XCTAssertEqual(AppRelocation.classify(bundlePath: "/Applications/PsyNeuView.app/"), .installed)
        XCTAssertEqual(AppRelocation.classify(bundlePath: "/Applications/./PsyNeuView.app"), .installed)
    }

    /// A path merely *containing* "Applications" is not /Applications — a folder
    /// called "My Applications" in Downloads must still prompt.
    func testLookAlikePathsStillPrompt() {
        let sneaky = "/Users/x/Downloads/My Applications/PsyNeuView.app"
        XCTAssertTrue(AppRelocation.classify(bundlePath: sneaky).needsMoving)
    }

    /// `make run` is `swift run`, which builds a bare executable rather than a
    /// bundle. `Bundle.main.bundlePath` then names the directory holding it, so
    /// every development run used to open with an offer to move `.build/debug`
    /// into /Applications. Every case above is a `.app`, which is how that got
    /// past the tests. (#166)
    func testDevelopmentBuildIsNotSomewhereToMoveFrom() {
        let path = "/Users/x/PsyNeuView-MacApp/.build/debug"
        XCTAssertEqual(AppRelocation.classify(bundlePath: path), .developmentBuild(path: path))
        XCTAssertFalse(AppRelocation.classify(bundlePath: path).needsMoving)
    }

    /// The point of the fix: a development run is asked nothing at all.
    ///
    /// Accepting was worse than the prompt. `moveToApplications` names the
    /// destination after the source's last path component, so the offer would
    /// have copied the build directory to `/Applications/debug`.
    func testDevelopmentBuildIsNotPrompted() {
        XCTAssertNil(AppRelocation.prompt(
            for: .developmentBuild(path: "/Users/x/PsyNeuView-MacApp/.build/debug")))
    }

    /// Bundle-ness is judged before location, so a checkout on an external disk
    /// is a development build rather than a disk image to be rescued.
    func testDevelopmentBuildOnAVolumeIsStillADevelopmentBuild() {
        let path = "/Volumes/Work/PsyNeuView-MacApp/.build/debug"
        XCTAssertEqual(AppRelocation.classify(bundlePath: path), .developmentBuild(path: path))
    }

    /// An installed bundle on an external volume is still a disk-image case —
    /// the check above must not have swallowed it.
    func testBundleOnAVolumeIsStillADiskImage() {
        let path = "/Volumes/PsyNeuView/PsyNeuView.app"
        XCTAssertEqual(AppRelocation.classify(bundlePath: path), .diskImage(path: path))
    }

    func testNoPromptWhenAlreadyInstalled() {
        XCTAssertNil(AppRelocation.prompt(for: .installed))
    }

    /// The disk-image wording is firmer than the Downloads wording on purpose:
    /// one is a volume that will be ejected, the other a folder that might move.
    func testDiskImageWordingNamesTheEjectProblem() {
        guard let prompt = AppRelocation.prompt(for: .diskImage(path: "/Volumes/PsyNeuView/PsyNeuView.app"))
        else { return XCTFail("a disk image must prompt") }
        XCTAssertTrue(prompt.body.contains("eject"))
    }

    func testElsewhereWordingNamesThePath() {
        guard let prompt = AppRelocation.prompt(for: .elsewhere(path: "/Users/x/Downloads/PsyNeuView.app"))
        else { return XCTFail("a non-Applications path must prompt") }
        XCTAssertTrue(prompt.body.contains("/Users/x/Downloads/PsyNeuView.app"))
    }

    /// Refuse rather than clobber an existing install.
    ///
    /// Against a temporary directory, not the real /Applications: an earlier
    /// version of this test passed here only because an app happened to be
    /// installed, and would have failed on a clean runner.
    func testMoveRefusesWhenSomethingIsAlreadyThere() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-move-\(UUID().uuidString)")
        let apps = root.appendingPathComponent("Applications")
        let source = root.appendingPathComponent("src/PsyNeuView.app")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: apps.appendingPathComponent("PsyNeuView.app"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try AppRelocation.moveToApplications(from: source.path, into: apps.path)
        ) { error in
            guard case AppRelocation.MoveError.destinationExists = error else {
                return XCTFail("expected destinationExists, got \(error)")
            }
        }
    }

    /// The successful path: the bundle lands in the destination and the original
    /// is left alone, because the source may be a read-only disk image.
    func testMoveCopiesRatherThanRemovingTheOriginal() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-move-\(UUID().uuidString)")
        let apps = root.appendingPathComponent("Applications")
        let source = root.appendingPathComponent("Volumes/PsyNeuView/PsyNeuView.app")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)

        let landed = try AppRelocation.moveToApplications(from: source.path, into: apps.path)
        XCTAssertEqual(landed, apps.appendingPathComponent("PsyNeuView.app").path)
        XCTAssertTrue(fm.fileExists(atPath: landed + "/Contents"))
        XCTAssertTrue(fm.fileExists(atPath: source.path),
                      "the source must survive — a disk image is read-only and a "
                      + "half-moved app is worse than one still on the DMG")
    }
}

/// PsyNeuView's models/ directory is both the discovery folder and where Save As
/// writes. In a bundled install it sits inside the tree this app deletes and
/// re-extracts — so saved work was living in disposable storage. A tester
/// reported a saved model that went missing.
/// (jonhanke-nam/PsyNeuView-archive#1089)
final class UserModelStorageTests: XCTestCase {

    /// Rescued models must land outside anything the app replaces — and in the
    /// one hidden folder PsyNeuView recognises as a legacy project folder
    /// (`model_dirs.legacy_models_dirs`, PsyNeuView-archive#1295), so what is rescued
    /// is found by the backend and offered a move, rather than lost (#212).
    func testUserModelsLiveOutsideTheBundledTree() {
        let user = BundledPsyNeuView.userModelsDirectory().path
        XCTAssertFalse(user.contains("Application Support/PsyNeuView/psyneuview-"),
                       "the versioned tree is deleted and re-extracted; nothing of the user's belongs in it")
        XCTAssertTrue(user.hasSuffix(".psyneuview/models"),
                      "must stay the path PsyNeuView lists as a legacy folder, or rescued models vanish")
    }

    /// Every .py under the tree's models/ was written by the user: the archive
    /// ships only README files there.
    func testRescueMovesUserModelsOutOfTheTree() throws {
        let fm = FileManager.default
        // A bundled install lives inside the app's support directory; only such
        // a folder is rescued from (#199), so the test tree sits in one.
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-support-\(UUID().uuidString)")
        let tree = support.appendingPathComponent("psyneuview-0.5.0")
        let models = tree.appendingPathComponent("models/custom")
        defer { try? fm.removeItem(at: support) }
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        try "# shipped".write(to: tree.appendingPathComponent("models/README.md"),
                              atomically: true, encoding: .utf8)
        try "# mine".write(to: tree.appendingPathComponent("models/main.py"),
                           atomically: true, encoding: .utf8)
        try "# nested".write(to: models.appendingPathComponent("deep.py"),
                             atomically: true, encoding: .utf8)

        let rescued = BundledPsyNeuView.rescueUserModels(fromTree: tree, supportDirectory: support)
        defer {
            for name in rescued {
                try? fm.removeItem(at: BundledPsyNeuView.userModelsDirectory()
                    .appendingPathComponent(name))
            }
        }

        XCTAssertEqual(Set(rescued), ["main.py", "deep.py"],
                       "nested models count too — the folder is scanned recursively")
        XCTAssertFalse(fm.fileExists(atPath: tree.appendingPathComponent("models/main.py").path),
                       "rescued means moved, not copied; a copy left behind is still at risk")
        XCTAssertTrue(fm.fileExists(atPath: tree.appendingPathComponent("models/README.md").path),
                      "shipped files stay — they belong to the app, not the user")
    }

    func testRescueOfAnUntouchedTreeDoesNothing() throws {
        let fm = FileManager.default
        let tree = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnv-rescue-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tree) }
        try fm.createDirectory(at: tree.appendingPathComponent("models"),
                               withIntermediateDirectories: true)
        try "# shipped".write(to: tree.appendingPathComponent("models/README.md"),
                              atomically: true, encoding: .utf8)
        XCTAssertTrue(BundledPsyNeuView.rescueUserModels(fromTree: tree).isEmpty)
    }

    func testRescueIsSafeWhenThereIsNoTree() {
        XCTAssertTrue(BundledPsyNeuView.rescueUserModels(
            fromTree: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }
}

/// About says when the app was built and the bundled PsyNeuView released (#15).
final class AboutDatesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let built = Date(timeIntervalSince1970: 1_792_089_180)    // 2026-10-15T18:33:00Z
    private let released = Date(timeIntervalSince1970: 1_792_173_776) // 2026-10-16T18:02:56Z

    func testWhenGivesTheDateTimeAndHowLongAgo() {
        let now = built.addingTimeInterval(2 * 3600)
        XCTAssertEqual(VersionReport.when(built, now: now, timeZone: utc), "Oct 15, 2026, 6:33 PM (2 hours ago)")
    }

    func testAgoInPlainWords() {
        XCTAssertEqual(VersionReport.ago(built, now: built.addingTimeInterval(30)), "just now")
        XCTAssertEqual(VersionReport.ago(built, now: built.addingTimeInterval(60)), "1 minute ago")
        XCTAssertEqual(VersionReport.ago(built, now: built.addingTimeInterval(5 * 86_400)), "5 days ago")
        XCTAssertEqual(VersionReport.ago(built, now: built.addingTimeInterval(-60)), "just now")
    }

    func testAboutSaysWhenTheAppWasBuiltAndPsyNeuViewReleased() {
        let now = released.addingTimeInterval(3600)
        let lines = VersionReport.aboutLines(
            appVersion: "0.6.2", appBuild: "0.6.2", psyNeuViewVersion: "0.6.2", checkoutPath: nil,
            psyNeuLinkVersion: nil, psyNeuLinkSource: nil, availableSources: [],
            identity: .release, buildCommit: "abc1234",
            appBuildDate: built, psyNeuViewReleased: released, now: now)
        XCTAssertTrue(lines[0].hasPrefix("PsyNeuView app 0.6.2, built "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix(" (25 hours ago) from commit abc1234"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("PsyNeuView 0.6.2, released "), lines[1])
        XCTAssertTrue(lines[1].hasSuffix(" (1 hour ago), included with this app"), lines[1])
    }

    func testAboutWithoutACommitStillSaysWhenBuilt() {
        let lines = VersionReport.aboutLines(
            appVersion: "0.6.2", appBuild: nil, psyNeuViewVersion: "0.6.2", checkoutPath: nil,
            psyNeuLinkVersion: nil, psyNeuLinkSource: nil, availableSources: [],
            appBuildDate: built, now: built)
        XCTAssertTrue(lines[0].hasPrefix("PsyNeuView app 0.6.2, built "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix(" (just now)"), lines[0])
        XCTAssertEqual(lines[1], "PsyNeuView 0.6.2, included with this app")
    }
}
