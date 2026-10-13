import Foundation
@testable import PsyNeuView

/// A sample report request, shared by the tests of the parts added in #208.
enum ReportSamples {
    static let home = "/Users/someone"
    static let utc = TimeZone(identifier: "UTC")!
    // 2026-10-06 14:03:22 UTC
    static let date = Date(timeIntervalSince1970: 1_791_295_402)

    static let facts = ProblemReport.Facts(
        appVersion: "0.5.19", appBuild: "42",
        psyNeuViewVersion: "0.5.13",
        install: "PsyNeuView 0.5.13, included with this app",
        psyNeuLinkSource: "github:devel",
        psyNeuLinkVersion: "0.19.1.0",
        developerMode: false,
        server: "running",
        startupOutcome: "started in 38.2 s",
        moveOutcome: nil,
        steps: [],
        macOSVersion: "Version 26.0 (Build 25A354)",
        macModel: "Mac15,6")

    static func request(
        logs: [String] = ["[2026-10-06 14:00:00.000] [System] Starting"],
        screenshots: [String] = ["screenshot-1.png"]
    ) -> ProblemReport.Request {
        ProblemReport.Request(
            whatHappened: "It stopped.", expected: "", facts: facts, logLines: logs,
            screenshots: screenshots, screenshotNote: nil,
            reference: ProblemReport.reference(for: date, timeZone: utc),
            date: date)
    }

    static func build(_ r: ProblemReport.Request) -> ProblemReport.Files {
        ProblemReport.build(r, home: home, timeZone: utc)
    }

    static func diagnostics(_ files: ProblemReport.Files) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: files.diagnostics) as? [String: Any]) ?? [:]
    }
}
