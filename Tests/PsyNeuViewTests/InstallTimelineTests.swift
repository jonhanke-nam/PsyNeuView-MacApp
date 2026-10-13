import XCTest
@testable import PsyNeuView

/// "Install PsyNeuLink and Python packages" split into what pip and uv were
/// doing, from their own output (#215).
final class InstallTimelineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// What pip prints installing PsyNeuLink from GitHub, without a terminal,
    /// with the moment each line arrived.
    private let pipTranscript: [(Double, String)] = [
        (0.4, "Collecting git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"),
        (0.5, "  Cloning https://github.com/PrincetonUniversity/PsyNeuLink.git (to revision devel) to /private/var/folders/x/pip-req-build-abc"),
        (0.6, "  Running command git clone --filter=blob:none --quiet https://github.com/PrincetonUniversity/PsyNeuLink.git /private/var/folders/x/pip-req-build-abc"),
        (11.9, "  Resolved https://github.com/PrincetonUniversity/PsyNeuLink.git to commit 1a2b3c4d"),
        (12.0, "  Installing build dependencies: started"),
        (15.0, "  Installing build dependencies: finished with status 'done'"),
        (15.1, "  Getting requirements to build wheel: started"),
        (17.0, "  Getting requirements to build wheel: finished with status 'done'"),
        (17.1, "  Preparing metadata (pyproject.toml): started"),
        (20.0, "  Preparing metadata (pyproject.toml): finished with status 'done'"),
        (20.1, "Collecting numpy<2.3,>=1.26 (from psyneulink==0.17.0.0)"),
        (20.5, "  Downloading numpy-2.2.6-cp314-cp314-macosx_14_0_arm64.whl.metadata (62 kB)"),
        (21.0, "Collecting torch (from psyneulink==0.17.0.0)"),
        (21.3, "  Downloading torch-2.8.0-cp314-none-macosx_11_0_arm64.whl.metadata (30 kB)"),
        (40.0, "Downloading torch-2.8.0-cp314-none-macosx_11_0_arm64.whl (73.9 MB)"),
        (44.0, "   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 73.9/73.9 MB 20.1 MB/s eta 0:00:00"),
        (44.1, "Downloading numpy-2.2.6-cp314-cp314-macosx_14_0_arm64.whl (5.0 MB)"),
        (45.0, "Using cached pillow-11.0.0-cp314-cp314-macosx_11_0_arm64.whl (3.0 MB)"),
        (100.0, "Building wheels for collected packages: psyneulink"),
        (100.1, "  Building wheel for psyneulink (pyproject.toml): started"),
        (119.0, "  Building wheel for psyneulink (pyproject.toml): finished with status 'done'"),
        (119.1, "  Created wheel for psyneulink: filename=psyneulink-0.17.0.0-py3-none-any.whl size=2134567 sha256=abc"),
        (119.9, "Successfully built psyneulink"),
        (120.0, "Installing collected packages: numpy, pillow, torch, psyneulink"),
        (179.0, "Successfully installed numpy-2.2.6 pillow-11.0.0 psyneulink-0.17.0.0 torch-2.8.0"),
    ]

    private func pipRun() -> InstallTimeline {
        var t = InstallTimeline(label: "PsyNeuLink (git+…@devel) with pip", id: "psyneulink", startedAt: t0)
        for (seconds, line) in pipTranscript { t.observe(line, at: at(seconds)) }
        t.finish(at: at(180))
        return t
    }

    func testPipPhasesAreTimedFromTheirAnnouncements() {
        let t = pipRun()
        XCTAssertEqual(t.entries.map(\.phase),
                       [.fetchSource, .buildMetadata, .resolveAndDownload, .buildWheel, .install])
        // Time before pip's first announcement belongs to the first phase.
        XCTAssertEqual(t.entries[0].seconds, 12.0, accuracy: 0.001)
        XCTAssertEqual(t.entries[1].seconds, 8.1, accuracy: 0.001)
        XCTAssertEqual(t.entries[2].seconds, 79.9, accuracy: 0.001)
        XCTAssertEqual(t.entries[3].seconds, 20.0, accuracy: 0.001)
        XCTAssertEqual(t.entries[4].seconds, 60.0, accuracy: 0.001)
        XCTAssertEqual(t.totalSeconds, 180)
    }

    func testWheelBytesAreCountedOnlyForRealDownloads() {
        let t = pipRun()
        // The two .metadata fetches and the cached wheel don't count; torch and
        // numpy do. pip's units are decimal.
        XCTAssertEqual(t.entries[2].bytes, 78_900_000)
        XCTAssertEqual(t.totalBytes, 78_900_000)
        XCTAssertNil(t.entries[0].bytes, "bytes belong to the download phase only")
        XCTAssertEqual(t.downloads.map(\.name).first, "torch-2.8.0-cp314-none-macosx_11_0_arm64.whl",
                       "largest first, so the log can name the heavy wheel")
        XCTAssertEqual(t.largestDownloads(2), "torch 73.9 MB, numpy 5.0 MB")
    }

    func testUvReportsItsOwnDurations() {
        var t = InstallTimeline(label: "Backend packages with uv", id: "backend", startedAt: t0)
        t.observe("Resolved 87 packages in 1.21s", at: at(2))
        t.observe("Prepared 3 packages in 2m 03s", at: at(130))
        t.observe("Installed 87 packages in 310ms", at: at(131))
        t.observe(" + aiofiles==24.1.0", at: at(131))
        t.finish(at: at(131.5))
        XCTAssertEqual(t.entries.map(\.phase), [.resolve, .prepare, .install])
        XCTAssertEqual(t.entries.map(\.seconds), [1.21, 123.0, 0.31])
        XCTAssertEqual(t.entries.map(\.packages), [87, 3, 87])
        XCTAssertEqual(t.totalBytes, 0, "uv prints no sizes without a terminal")
    }

    func testUvAuditIsAnInstallThatDidNothing() {
        XCTAssertEqual(InstallTimeline.uvPhase("Audited 1 package in 2ms")?.phase, .install)
        XCTAssertEqual(InstallTimeline.uvPhase("Audited 1 package in 2ms")?.seconds, 0.002)
        XCTAssertNil(InstallTimeline.uvPhase("Resolved https://github.com/x.git to commit abc"),
                     "pip's 'Resolved … to commit' is not uv's 'Resolved N packages'")
    }

    func testSizesAndDurationsParse() {
        XCTAssertEqual(InstallTimeline.bytes(fromSize: "73.9 MB"), 73_900_000)
        XCTAssertEqual(InstallTimeline.bytes(fromSize: "62 kB"), 62_000)
        XCTAssertEqual(InstallTimeline.bytes(fromSize: "1.2 GB"), 1_200_000_000)
        XCTAssertEqual(InstallTimeline.bytes(fromSize: "512 bytes"), 512)
        XCTAssertNil(InstallTimeline.bytes(fromSize: "lots"))
        XCTAssertEqual(InstallTimeline.seconds(fromUvDuration: "1.21s"), 1.21)
        XCTAssertEqual(InstallTimeline.seconds(fromUvDuration: "310ms"), 0.31)
        XCTAssertEqual(InstallTimeline.seconds(fromUvDuration: "2m 03s"), 123)
        XCTAssertEqual(InstallTimeline.seconds(fromUvDuration: "1h 2m 3s"), 3723)
        XCTAssertNil(InstallTimeline.seconds(fromUvDuration: "soon"))
        XCTAssertEqual(InstallTimeline.format(bytes: 73_900_000), "73.9 MB")
        XCTAssertEqual(InstallTimeline.format(bytes: 62_000), "62 kB")
    }

    func testDetailsCarryStableIdsAndTheTotal() {
        let details = pipRun().details()
        XCTAssertEqual(details.map(\.id), [
            "psyneulink/fetchSource", "psyneulink/buildMetadata", "psyneulink/resolveAndDownload",
            "psyneulink/buildWheel", "psyneulink/install", "psyneulink/total",
        ])
        XCTAssertEqual(details.last?.seconds, 180)
        XCTAssertEqual(details.last?.bytes, 78_900_000)
        XCTAssertTrue(details[0].title.hasPrefix("PsyNeuLink (git+…@devel) with pip: "))
    }

    func testTheSummaryNamesTheHeavyWheel() {
        let line = Installer.summary(of: pipRun())
        XCTAssertTrue(line.contains("180.0 s"), line)
        XCTAssertTrue(line.contains("fetch the source (git clone) 12.0 s"), line)
        XCTAssertTrue(line.contains("78.9 MB downloaded: torch 73.9 MB"), line)
    }

    func testAnUnfinishedRunHasNoTotal() {
        var t = InstallTimeline(label: "x", id: "x", startedAt: t0)
        t.observe("Collecting numpy", at: at(1))
        XCTAssertNil(t.totalSeconds)
        XCTAssertTrue(t.entries.isEmpty, "a phase is only closed by the next one, or by finish")
        XCTAssertTrue(t.details().isEmpty)
    }

    func testRepeatedAnnouncementsStayInOnePhase() {
        var t = InstallTimeline(label: "x", id: "x", startedAt: t0)
        t.observe("Collecting a", at: at(1))
        t.observe("Collecting b", at: at(2))
        t.observe("Requirement already satisfied: c", at: at(3))
        t.observe("Installing collected packages: a, b", at: at(4))
        t.finish(at: at(5))
        XCTAssertEqual(t.entries.map(\.phase), [.resolveAndDownload, .install])
        XCTAssertEqual(t.entries[0].seconds, 4, accuracy: 0.001)
    }
}
