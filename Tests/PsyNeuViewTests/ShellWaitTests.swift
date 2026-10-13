import XCTest
@testable import PsyNeuView

/// A command that exits at once must still be reported as finished (#185).
///
/// The termination handler used to be attached after `process.run()`. A
/// command that finished in between, like a small fast-forward `git pull`,
/// left nothing to resume the wait, and launch hung on "Starting the
/// PsyNeuView server…". The race needs a fast command, so this runs one many
/// times, and fails by timing out rather than by hanging the suite.
final class ShellWaitTests: XCTestCase {

    func testAnInstantCommandIsAlwaysReportedFinished() async {
        for _ in 0..<200 {
            let status = await withTimeout(seconds: 5) {
                await Shell.runStreaming("true", onOutput: { _ in })
            }
            XCTAssertEqual(status, 0, "an instantly-finishing command was never reported finished")
            if status != 0 { return }
        }
    }

    func testTheExitStatusComesThrough() async {
        let status = await withTimeout(seconds: 5) {
            await Shell.runStreaming("false", onOutput: { _ in })
        }
        XCTAssertEqual(status, 1)
    }

    func testOutputStillArrives() async {
        let box = OutputBox()
        let status = await withTimeout(seconds: 5) {
            await Shell.runStreaming("sh", arguments: ["-c", "echo hello; sleep 0.2"],
                                     onOutput: { box.append($0) })
        }
        XCTAssertEqual(status, 0)
        XCTAssertTrue(box.text.contains("hello"))
    }

    func testACommandThatCannotStartReturnsInsteadOfHanging() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/definitely-not-here")
        let status = await withTimeout(seconds: 5) {
            await Shell.runAndWait(process, pipes: [], onOutput: { _ in })
        }
        XCTAssertEqual(status, -1)
    }

    /// Runs `body`, or gives up with a sentinel after `seconds`.
    private func withTimeout(seconds: Double, _ body: @escaping @Sendable () async -> Int32) async -> Int32 {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? Int32.min
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func append(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
}
