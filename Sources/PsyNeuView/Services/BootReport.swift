import Foundation

/// Measuring how long starting actually takes (#104).
///
/// 0.5.3 shipped a 30-second ceiling against a 38.67-second warm-up. Nothing
/// objected, because nothing measured anything: the tests compared one constant
/// to another, and every development machine had PsyNeuLink already imported
/// and a warm filesystem cache. The slow path — the normal first run on someone
/// else's Mac — never executed here.
///
/// A ceiling is only meaningful next to a measurement. This records what a real
/// start cost so CI can fail when the headroom gets thin, rather than when a
/// user's install does.
enum BootReport {

    /// Where to write the measurement, when asked.
    ///
    /// Set `PSYNEUVIEW_BOOT_REPORT=/path/to/report.json` and the app writes its
    /// startup time there and quits. Absent — which is every normal launch —
    /// nothing is written and nothing changes.
    static var reportPath: String? {
        ProcessInfo.processInfo.environment["PSYNEUVIEW_BOOT_REPORT"]
    }

    /// One step of the launch with its time, for the per-step breakdown
    /// (#215). `id` is stable across releases — a checklist step's name
    /// (`installPackages`), or a step and a part of it
    /// (`installPackages/psyneulink/resolveAndDownload`) — so
    /// measure-boot.sh can compare this run's steps with a recorded baseline.
    struct StepTiming: Codable, Equatable, Sendable {
        let id: String
        let title: String
        /// Nil when the step was skipped or never reached.
        let seconds: Double?
        /// Bytes downloaded during the step, when known.
        let bytes: Int64?
    }

    struct Measurement: Codable, Equatable {
        /// Seconds from asking services to start until the backend answered.
        let seconds: Double
        /// The ceiling in force, so a report is interpretable on its own.
        let ceiling: Double
        /// False when the ceiling was hit or the process died first.
        let healthy: Bool
        /// The launch step by step, when the app had a checklist running —
        /// a first launch's install included (#215). Absent in a report
        /// written by an app without one, and in older reports.
        let steps: [StepTiming]?

        init(seconds: Double, ceiling: Double, healthy: Bool, steps: [StepTiming]? = nil) {
            self.seconds = seconds
            self.ceiling = ceiling
            self.healthy = healthy
            self.steps = steps
        }

        /// How much of the allowance this start consumed.
        var fractionOfCeiling: Double {
            ceiling > 0 ? seconds / ceiling : 1
        }
    }

    /// Whether a measured start leaves enough room to be worth trusting.
    ///
    /// Pure, so the rule is testable without launching anything.
    ///
    /// The threshold is a fraction rather than a fixed number of seconds
    /// because the thing worth catching is *drift toward the ceiling*, not any
    /// particular duration. A CI runner is not a cold Mac; what transfers is
    /// the ratio.
    static func hasHeadroom(_ m: Measurement, warnAbove fraction: Double = 0.25) -> Bool {
        m.healthy && m.fractionOfCeiling <= fraction
    }

    /// One line a human can read in CI output.
    static func summary(_ m: Measurement, warnAbove fraction: Double = 0.25) -> String {
        guard m.healthy else {
            return String(format: "boot: FAILED after %.1fs (ceiling %.0fs)",
                          m.seconds, m.ceiling)
        }
        let percent = m.fractionOfCeiling * 100
        let verdict = hasHeadroom(m, warnAbove: fraction) ? "ok" : "TOO CLOSE TO THE CEILING"
        return String(format: "boot: healthy in %.1fs — %.1f%% of the %.0fs ceiling — %@",
                      m.seconds, percent, m.ceiling, verdict)
    }

    /// Write the measurement, if one was asked for.
    ///
    /// Failures here are deliberately silent: a report that cannot be written
    /// must not take down an app someone is trying to use. CI notices the
    /// missing file.
    static func write(_ m: Measurement, to path: String? = reportPath) {
        guard let path else { return }
        guard let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
