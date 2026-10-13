import Foundation
import XCTest
@testable import PsyNeuView

/// Measuring how long starting takes (#104).
///
/// 0.5.3 shipped a 30s ceiling against a 38.67s warm-up and nothing objected,
/// because the tests compared one constant to another. A ceiling only means
/// something next to a measurement.
final class BootReportTests: XCTestCase {

    private func measurement(
        _ seconds: Double, ceiling: Double = 600, healthy: Bool = true
    ) -> BootReport.Measurement {
        .init(seconds: seconds, ceiling: ceiling, healthy: healthy)
    }

    func testAFastStartHasHeadroom() {
        XCTAssertTrue(BootReport.hasHeadroom(measurement(3.1)))
    }

    func testAStartCreepingTowardTheCeilingDoesNot() {
        // The failure this exists to catch: not any particular duration, but
        // drift toward the limit.
        XCTAssertFalse(BootReport.hasHeadroom(measurement(200, ceiling: 600)))
    }

    func testTheThresholdIsAFractionNotASecondCount() {
        // A CI runner is not a cold Mac. What transfers between machines is the
        // ratio, so the same seconds pass or fail depending on the ceiling.
        XCTAssertTrue(BootReport.hasHeadroom(measurement(60, ceiling: 600)))
        XCTAssertFalse(BootReport.hasHeadroom(measurement(60, ceiling: 120)))
    }

    func testAFailedStartNeverHasHeadroom() {
        // However fast it was. Failing quickly is still failing.
        XCTAssertFalse(BootReport.hasHeadroom(measurement(0.5, healthy: false)))
    }

    func testTheHistoricalFailureWouldBeCaught() {
        // 38.67s against the 30s ceiling that shipped.
        XCTAssertFalse(BootReport.hasHeadroom(measurement(38.67, ceiling: 30)))
        // And against today's ceiling it is comfortable, which is why the
        // ceiling was raised rather than the warm-up made faster.
        XCTAssertTrue(BootReport.hasHeadroom(measurement(38.67, ceiling: 600)))
    }

    func testTheSummarySaysWhatHappened() {
        let ok = BootReport.summary(measurement(3.1))
        XCTAssertTrue(ok.contains("3.1s"))
        XCTAssertTrue(ok.contains("ok"))

        let bad = BootReport.summary(measurement(200))
        XCTAssertTrue(bad.contains("TOO CLOSE"))

        let failed = BootReport.summary(measurement(5, healthy: false))
        XCTAssertTrue(failed.contains("FAILED"))
    }

    func testAZeroCeilingIsNotTreatedAsInfiniteHeadroom() {
        // Division guard: a misconfigured ceiling must not read as "plenty of
        // room", which is the direction that fails silently.
        XCTAssertFalse(BootReport.hasHeadroom(measurement(1, ceiling: 0)))
    }

    func testTheMeasurementRoundTripsAsJSON() throws {
        // CI reads this file; an encoding change would break the canary
        // quietly.
        let original = measurement(3.1195)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BootReport.Measurement.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// The per-step breakdown rides along (#215), with the ids
    /// measure-boot.sh compares against its baseline, and bytes where known.
    func testTheStepsRoundTripAsJSON() throws {
        let original = BootReport.Measurement(seconds: 38.6, ceiling: 600, healthy: true, steps: [
            .init(id: "installPackages", title: "Install PsyNeuLink and Python packages", seconds: 240.1, bytes: nil),
            .init(id: "installPackages/psyneulink/resolveAndDownload",
                  title: "PsyNeuLink (git+…@devel) with pip: resolve dependencies and download wheels",
                  seconds: 95.0, bytes: 310_200_000),
            .init(id: "startServer", title: "Start the server and load PsyNeuLink", seconds: 38.6, bytes: nil),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BootReport.Measurement.self, from: data)
        XCTAssertEqual(decoded, original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        XCTAssertEqual(steps[1]["id"] as? String, "installPackages/psyneulink/resolveAndDownload")
        XCTAssertEqual(steps[1]["bytes"] as? Int64, 310_200_000)
    }

    /// A report from an app without a checklist, or an older one, still reads.
    func testAReportWithoutStepsStillReads() throws {
        let data = Data(#"{"seconds":3.1,"ceiling":600,"healthy":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BootReport.Measurement.self, from: data)
        XCTAssertNil(decoded.steps)
        XCTAssertTrue(BootReport.hasHeadroom(decoded))
    }
}
