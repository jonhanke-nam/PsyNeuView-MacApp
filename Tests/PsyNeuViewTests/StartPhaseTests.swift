import XCTest
@testable import PsyNeuView

/// The backend's start-phase lines (#232): parsed as data, never trusted to
/// be well formed, and mapped onto the checklist.
final class StartPhaseTests: XCTestCase {

    // MARK: Parsing

    func testAWellFormedLineParses() {
        let phase = StartPhase.parse("PNV-START import-psyneulink end elapsed=12.5")
        XCTAssertEqual(phase, StartPhase(phase: .importPsyNeuLink, event: .end, elapsed: 12.5, detail: nil))
    }

    func testBeginHasNoElapsed() {
        XCTAssertEqual(StartPhase.parse("PNV-START migrate begin"),
                       StartPhase(phase: .migrate, event: .begin, elapsed: nil, detail: nil))
    }

    func testDetailIsUrlDecoded() {
        let phase = StartPhase.parse("PNV-START pnl-update skip detail=already%20at%20the%20tip%20of%20devel")
        XCTAssertEqual(phase?.event, .skip)
        XCTAssertEqual(phase?.detail, "already at the tip of devel")
        XCTAssertEqual(StartPhase.parse("PNV-START warm-worker skip detail=already+warm")?.detail, "already warm")
    }

    func testReadyEndCarriesTheTotal() {
        let phase = StartPhase.parse("PNV-START ready end elapsed=24.8 detail=total")
        XCTAssertEqual(phase?.phase, .ready)
        XCTAssertEqual(phase?.elapsed, 24.8)
        XCTAssertEqual(phase?.detail, "total")
    }

    func testTrailingWhitespaceAndNewlinesAreFine() {
        XCTAssertNotNil(StartPhase.parse("  PNV-START warm-worker begin \r\n"))
    }

    func testAMarkerAfterALoggerPrefixStillParses() {
        // A logger that prefixes the line is tolerated, as long as the marker
        // starts a word.
        XCTAssertEqual(StartPhase.parse("INFO: PNV-START migrate end elapsed=0.3")?.phase, .migrate)
        XCTAssertNil(StartPhase.parse("xPNV-START migrate end"))
    }

    func testOrdinaryBackendOutputIsNotAPhase() {
        XCTAssertNil(StartPhase.parse("INFO:     Uvicorn running on http://127.0.0.1:8000"))
        XCTAssertNil(StartPhase.parse(""))
        XCTAssertNil(StartPhase.parse("PNV-START"))
    }

    func testMalformedLinesAreIgnored() {
        XCTAssertNil(StartPhase.parse("PNV-START migrate"))                 // no event
        XCTAssertNil(StartPhase.parse("PNV-START migrate finished"))        // unknown event
        XCTAssertNil(StartPhase.parse("PNV-START begin migrate"))           // swapped
    }

    func testAnUnknownPhaseFromANewerBackendIsIgnored() {
        XCTAssertNil(StartPhase.parse("PNV-START compile-bytecode begin"))
    }

    func testABadElapsedIsDroppedNotFatal() {
        let phase = StartPhase.parse("PNV-START migrate end elapsed=soon detail=ok")
        XCTAssertEqual(phase?.phase, .migrate)
        XCTAssertNil(phase?.elapsed)
        XCTAssertEqual(phase?.detail, "ok")
        XCTAssertNil(StartPhase.parse("PNV-START migrate end elapsed=-1")?.elapsed)
        XCTAssertNil(StartPhase.parse("PNV-START migrate end elapsed=nan")?.elapsed)
    }

    func testUnknownFieldsAreSkipped() {
        let phase = StartPhase.parse("PNV-START warm-worker end pid=42 elapsed=3 colour=blue")
        XCTAssertEqual(phase?.elapsed, 3)
    }

    func testEachPhaseMapsToItsStep() {
        XCTAssertEqual(StartPhase.parse("PNV-START migrate begin")?.step, .startServer)
        XCTAssertEqual(StartPhase.parse("PNV-START pnl-update begin")?.step, .installPsyNeuLinkUpdate)
        XCTAssertEqual(StartPhase.parse("PNV-START import-psyneulink begin")?.step, .loadPsyNeuLink)
        XCTAssertEqual(StartPhase.parse("PNV-START warm-worker begin")?.step, .warmModelRunner)
        XCTAssertNil(StartPhase.parse("PNV-START ready end")?.step)
    }

    // MARK: Lines across chunks

    func testALineSplitAcrossTwoChunksIsReadWhole() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.lines(from: "PNV-START import-psy"), [])
        XCTAssertEqual(splitter.lines(from: "neulink begin\nINFO: next\n"),
                       ["PNV-START import-psyneulink begin", "INFO: next"])
        XCTAssertNil(splitter.flush())
        XCTAssertEqual(splitter.lines(from: "tail"), [])
        XCTAssertEqual(splitter.flush(), "tail")
    }

    func testCarriageReturnsEndLinesToo() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.lines(from: "a\r\nb\rc\n"), ["a", "b", "c"])
    }
}

/// The phases drive the checklist (#232), and an older backend that reports
/// none still gets a checklist that closes properly.
@MainActor
final class StartPhaseProgressTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func line(_ text: String) -> StartPhase {
        guard let phase = StartPhase.parse(text) else {
            XCTFail("unparseable: \(text)")
            return StartPhase(phase: .ready, event: .begin, elapsed: nil, detail: nil)
        }
        return phase
    }

    func testPhasesBecomeStepsWithTheirOwnClocks() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .start), startedAt: t0)
        progress.begin(.startServer, at: at(0))
        progress.apply(line("PNV-START migrate begin"), at: at(1))
        progress.apply(line("PNV-START migrate end elapsed=0.4"), at: at(1.4))
        progress.apply(line("PNV-START pnl-update skip detail=up%20to%20date"), at: at(1.5))
        progress.apply(line("PNV-START import-psyneulink begin"), at: at(2))
        XCTAssertEqual(progress.currentStep, .loadPsyNeuLink)
        XCTAssertEqual(progress.statuses[.startServer], .done(seconds: 2))
        progress.apply(line("PNV-START import-psyneulink end elapsed=20"), at: at(22))
        progress.apply(line("PNV-START warm-worker begin"), at: at(22))
        progress.apply(line("PNV-START warm-worker end elapsed=3"), at: at(25))
        progress.apply(line("PNV-START ready end elapsed=25"), at: at(25))
        progress.serverAnsweredHealth(at: at(25.5))

        XCTAssertEqual(progress.states(at: at(26)).map(\.status), [
            .done(seconds: 2), .done(seconds: 20), .done(seconds: 3),
        ])
        // The update was skipped, so it never appeared as a step.
        XCTAssertFalse(progress.steps.contains(.installPsyNeuLinkUpdate))
        XCTAssertNil(progress.currentStep)
        // The backend's own clocks reach the report.
        XCTAssertEqual(progress.bootTimings(at: at(26)).map(\.id), [
            "startServer", "startServer/backend/migrate", "startServer/backend-total",
            "loadPsyNeuLink", "loadPsyNeuLink/backend/import-psyneulink",
            "warmModelRunner", "warmModelRunner/backend/warm-worker",
        ])
    }

    func testAPsyNeuLinkUpdateAppearsOnlyWhenItBegins() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .start), startedAt: t0)
        progress.begin(.startServer, at: at(0))
        progress.apply(line("PNV-START pnl-update begin detail=0.20.3"), at: at(1))
        XCTAssertEqual(progress.steps, [.startServer, .installPsyNeuLinkUpdate, .loadPsyNeuLink, .warmModelRunner])
        XCTAssertEqual(progress.currentStep, .installPsyNeuLinkUpdate)
        XCTAssertEqual(progress.statuses[.startServer], .done(seconds: 1))
        progress.apply(line("PNV-START pnl-update end elapsed=120"), at: at(121))
        progress.apply(line("PNV-START import-psyneulink begin"), at: at(121))
        XCTAssertEqual(progress.statuses[.installPsyNeuLinkUpdate], .done(seconds: 120))
        XCTAssertEqual(progress.currentStep, .loadPsyNeuLink)
    }

    func testAnOlderBackendWithNoPhasesFallsBackToOneServerStep() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .start), startedAt: t0)
        progress.begin(.startServer, at: at(0))
        progress.serverAnsweredHealth(at: at(30))
        XCTAssertEqual(progress.states(at: at(31)).map(\.status), [
            .done(seconds: 30),
            .skipped(reason: "counted in Starting the server"),
            .skipped(reason: "counted in Starting the server"),
        ])
        XCTAssertNil(progress.currentStep)
        XCTAssertFalse(progress.sawServerPhases)
    }

    func testHealthClosesAStepWhoseEndLineWasLost() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .start), startedAt: t0)
        progress.begin(.startServer, at: at(0))
        progress.apply(line("PNV-START import-psyneulink begin"), at: at(2))
        progress.apply(line("PNV-START warm-worker begin"), at: at(20))
        // No warm-worker end, no ready: /health arrives anyway.
        progress.serverAnsweredHealth(at: at(23))
        XCTAssertEqual(progress.states(at: at(24)).map(\.status), [
            .done(seconds: 2), .done(seconds: 18), .done(seconds: 3),
        ])
    }

    func testASkippedImportSaysWhy() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .start), startedAt: t0)
        progress.begin(.startServer, at: at(0))
        progress.apply(line("PNV-START import-psyneulink skip detail=already%20imported"), at: at(1))
        XCTAssertEqual(progress.statuses[.loadPsyNeuLink], .skipped(reason: "already imported"))
        progress.apply(line("PNV-START warm-worker skip"), at: at(1))
        XCTAssertEqual(progress.statuses[.warmModelRunner], .skipped(reason: "already warm"))
    }

    func testPhasesOnAChecklistWithoutAServerStepAreIgnored() {
        let progress = InstallProgress(steps: ProgressPlan.steps(for: .bundledSetup), startedAt: t0)
        progress.apply(line("PNV-START import-psyneulink begin"), at: at(1))
        XCTAssertNil(progress.currentStep)
        XCTAssertFalse(progress.steps.contains(.loadPsyNeuLink))
        progress.serverAnsweredHealth(at: at(2))
        XCTAssertEqual(progress.states(at: at(3)).map(\.status),
                       Array(repeating: .pending, count: progress.steps.count))
    }
}
