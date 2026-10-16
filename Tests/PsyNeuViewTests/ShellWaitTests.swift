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

    /// `Shell.run` too (#13): it waited with `waitUntilExit()`, which listens on
    /// the launching thread's run loop, and resumed elsewhere after its awaits.
    /// On CI a `git rev-parse` stalled that way with its git long gone. Many
    /// runs, because which thread it resumes on is luck.
    func testShellRunAlwaysReportsAFinishedCommand() async {
        for i in 0..<200 {
            let result = await giveUpAfter(seconds: 5) {
                (try? await Shell.run("sh", arguments: ["-c", "echo \(i)"]))?.stdout
            }
            XCTAssertEqual(result, "\(i)\n", "Shell.run never returned for run \(i)")
            if result != "\(i)\n" { return }
        }
    }

    /// Like `withTimeout`, but returns on time even if `body` never does: a
    /// task group would wait for its stuck child before returning.
    private func giveUpAfter<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async -> T?) async -> T? {
        let first = FirstOnly()
        return await withCheckedContinuation { continuation in
            Task {
                let value = await body()
                if first.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if first.claim() { continuation.resume(returning: nil) }
            }
        }
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

/// True for the first caller only.
private final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
