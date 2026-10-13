import Foundation
import XCTest

@testable import PsyNeuView

/// The reinstall gate reads dependencies, not the whole file (#144).
///
/// A routine `devel` pull once cost two minutes because PsyNeuView #1146 bumped
/// `version = "0.1.0"` to `"0.5.4"` and the updater reinstalled on the strength
/// of the file having changed. The reinstall re-resolves PsyNeuLink from a git
/// branch URL, which pip cannot cache, so it re-clones the whole repository.
/// Since the version is now a literal that moves with every release, that would
/// have happened on every release from then on.
///
/// The gate is a small python script embedded in `Updater.swift`. These read it
/// out of the source and run it, so the thing under test is the text that ships
/// rather than a copy that can drift.
final class DependencySignatureTests: XCTestCase {

    /// The script as embedded in Updater.swift, de-indented to column zero.
    private static func embeddedScript() throws -> String {
        let updater = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PsyNeuView/Services/Updater.swift")
        let source = try String(contentsOf: updater, encoding: .utf8)

        guard let start = source.range(of: "let script = \"\"\"\n"),
              let end = source.range(of: "\n        \"\"\"", range: start.upperBound..<source.endIndex)
        else {
            throw XCTSkip("Could not locate the embedded script in Updater.swift")
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        return body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("        ") ? String($0.dropFirst(8)) : String($0) }
            .joined(separator: "\n")
    }

    private var scriptPath: URL!

    override func setUpWithError() throws {
        let script = try Self.embeddedScript()
        scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sig-\(UUID().uuidString).py")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        // tomllib needs 3.11+; skip rather than fail on an older toolchain host.
        let probe = try run(arguments: ["python3", "-c", "import tomllib"])
        if probe.status != 0 {
            throw XCTSkip("python3 with tomllib is unavailable on this host")
        }
    }

    override func tearDown() {
        if let scriptPath { try? FileManager.default.removeItem(at: scriptPath) }
    }

    private func run(arguments: [String]) throws -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// nil mirrors Updater's "cannot tell", which callers treat as "reinstall".
    private func signature(of toml: String) throws -> String? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-\(UUID().uuidString).toml")
        try toml.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let result = try run(arguments: ["python3", scriptPath.path, path.path])
        guard result.status == 0 else { return nil }
        let trimmed = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private let base = """
        [build-system]
        requires = ["setuptools>=68.0", "wheel"]
        build-backend = "setuptools.build_meta"

        [project]
        name = "psynewview"
        version = "0.5.4"
        description = "Web-first graphical interface for PsyNeuLink"
        requires-python = ">=3.12,<3.15"
        dependencies = [
            "fastapi>=0.110.0",
            "psyneulink",
        ]
        """

    func testVersionBumpAloneDoesNotCountAsADependencyChange() throws {
        let bumped = base.replacingOccurrences(of: #"version = "0.5.4""#, with: #"version = "0.6.0""#)
        XCTAssertNotEqual(bumped, base, "the version substitution did not apply")
        XCTAssertEqual(try signature(of: base), try signature(of: bumped))
    }

    func testDescriptionChangeDoesNotCountEither() throws {
        let edited = base.replacingOccurrences(of: "Web-first graphical", with: "Graphical")
        XCTAssertNotEqual(edited, base, "the description substitution did not apply")
        XCTAssertEqual(try signature(of: base), try signature(of: edited))
    }

    func testAChangedDependencyIsDetected() throws {
        let edited = base.replacingOccurrences(of: "fastapi>=0.110.0", with: "fastapi>=0.120.0")
        XCTAssertNotEqual(edited, base, "the dependency substitution did not apply")
        XCTAssertNotEqual(try signature(of: base), try signature(of: edited))
    }

    func testAnAddedDependencyIsDetected() throws {
        let edited = base.replacingOccurrences(
            of: #""psyneulink","#, with: #""psyneulink", "httpx","#
        )
        XCTAssertNotEqual(edited, base, "the dependency substitution did not apply")
        XCTAssertNotEqual(try signature(of: base), try signature(of: edited))
    }

    func testRequiresPythonIsDetected() throws {
        let edited = base.replacingOccurrences(of: #">=3.12,<3.15"#, with: #">=3.13"#)
        XCTAssertNotEqual(edited, base, "the requires-python substitution did not apply")
        XCTAssertNotEqual(try signature(of: base), try signature(of: edited))
    }

    func testBuildRequiresIsDetected() throws {
        let edited = base.replacingOccurrences(
            of: #"requires = ["setuptools>=68.0", "wheel"]"#,
            with: #"requires = ["setuptools>=68.0", "wheel", "setuptools-scm"]"#
        )
        XCTAssertNotEqual(edited, base, "the build-requires substitution did not apply")
        XCTAssertNotEqual(try signature(of: base), try signature(of: edited))
    }

    /// Reordering installs the same things, so it must not force a reinstall.
    func testDependencyOrderDoesNotMatter() throws {
        let reordered = base.replacingOccurrences(
            of: "\"fastapi>=0.110.0\",\n    \"psyneulink\",",
            with: "\"psyneulink\",\n    \"fastapi>=0.110.0\","
        )
        XCTAssertNotEqual(reordered, base, "the reorder substitution did not apply")
        XCTAssertEqual(try signature(of: base), try signature(of: reordered))
    }

    /// Unparseable input must read as "cannot tell", never as "nothing changed".
    func testUnparseableTOMLYieldsNoSignature() throws {
        XCTAssertNil(try signature(of: "this is not = = valid toml [[[\n"))
    }
}
