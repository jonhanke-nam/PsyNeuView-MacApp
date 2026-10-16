import XCTest
@testable import PsyNeuView

/// Moving a checkout onto origin's rebuilt history, against real repositories:
/// an origin whose branch was replaced by unrelated history, and a clone made
/// before that. The clone's own commits must survive on the backup branch,
/// untracked files must be left alone, and a file in the way must stop the
/// move without changing anything.
final class CheckoutHistoryMoveTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkout-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) async throws -> String {
        let r = try await within("git \(args.joined(separator: " "))") {
            try await Shell.run("git", arguments: args, currentDirectory: dir)
        }
        XCTAssertEqual(r.exitCode, 0, "git \(args.joined(separator: " ")): \(r.stderr)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `work`, but fails the test after `seconds` instead of hanging the
    /// whole suite, and says which step it was and what git was still doing.
    /// Steps are written to stderr as they start: the test log is buffered
    /// and lost when CI kills a hung run.
    private func within<T: Sendable>(
        _ what: String, seconds: Double = 60, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        FileHandle.standardError.write(Data("[CheckoutHistoryMoveTests] \(what)\n".utf8))
        let first = Once()
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do { let v = try await work(); if first.claim() { continuation.resume(returning: v) } }
                catch { if first.claim() { continuation.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if first.claim() {
                    FileHandle.standardError.write(Data("[CheckoutHistoryMoveTests] TIMED OUT: \(what)\n\(CheckoutHistoryMoveTests.gitProcesses())\n".utf8))
                    continuation.resume(throwing: StepTimedOut(what: what))
                }
            }
        }
    }

    private static func gitProcesses() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ax", "-o", "pid,ppid,stat,etime,command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        return text.split(separator: "\n").filter { $0.contains("git") }.joined(separator: "\n")
    }

    private func write(_ text: String, to name: String, in dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A checkout cloned from origin, then origin's `devel` replaced by an
    /// unrelated history, then fetched — what an existing checkout sees.
    private func checkoutAfterRebuild() async throws -> (checkout: URL, oldHead: String, newHead: String) {
        let origin = root.appendingPathComponent("origin")
        let checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        let ident = ["-c", "user.name=Test", "-c", "user.email=test@example.org"]
        try await git(["init", "-q", "-b", "devel"], in: origin)
        try write("old\n", to: "app.txt", in: origin)
        try await git(["add", "."], in: origin)
        try await git(ident + ["commit", "-q", "-m", "old history"], in: origin)
        try await git(["clone", "-q", origin.path, checkout.path], in: root)
        try write("mine\n", to: "app.txt", in: checkout)
        try await git(ident + ["commit", "-q", "-am", "a local commit"], in: checkout)
        let oldHead = try await git(["rev-parse", "HEAD"], in: checkout)

        // Rebuild origin's devel: a new root commit, unrelated to the old one.
        try await git(["checkout", "-q", "--orphan", "rebuilt"], in: origin)
        try write("new\n", to: "app.txt", in: origin)
        try await git(["add", "."], in: origin)
        try await git(ident + ["commit", "-q", "-m", "rebuilt history"], in: origin)
        try await git(["branch", "-q", "-M", "rebuilt", "devel"], in: origin)
        let newHead = try await git(["rev-parse", "HEAD"], in: origin)
        try await git(["fetch", "-q", "origin", "devel"], in: checkout)
        return (checkout, oldHead, newHead)
    }

    func testMoveKeepsOwnCommitsAndUntrackedFiles() async throws {
        let (checkout, oldHead, newHead) = try await checkoutAfterRebuild()
        try write("notes\n", to: "untracked.txt", in: checkout)
        let day = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!

        let moved = try await within("moveToNewHistory") {
            await Updater.moveToNewHistory(branch: "devel", repoPath: checkout, on: day, log: { _ in })
        }

        XCTAssertTrue(moved)
        let head = try await git(["rev-parse", "HEAD"], in: checkout)
        XCTAssertEqual(head, newHead, "devel follows the rebuilt history")
        let backup = try await git(["rev-parse", "old-history/devel-20261014"], in: checkout)
        XCTAssertEqual(backup, oldHead, "the checkout's own commits are on the backup branch")
        let untracked = try String(contentsOf: checkout.appendingPathComponent("untracked.txt"), encoding: .utf8)
        XCTAssertEqual(untracked, "notes\n")
        let branch = try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: checkout)
        XCTAssertEqual(branch, "devel", "still on the same branch")
    }

    /// An untracked file where the new history has a tracked one: `reset
    /// --keep` refuses, and the checkout is left exactly as it was.
    func testAFileInTheWayStopsTheMoveAndChangesNothing() async throws {
        let (checkout, oldHead, _) = try await checkoutAfterRebuild()
        // The rebuilt history doesn't track this name, so make one it does.
        let origin = root.appendingPathComponent("origin")
        let ident = ["-c", "user.name=Test", "-c", "user.email=test@example.org"]
        try write("tracked upstream\n", to: "clash.txt", in: origin)
        try await git(["add", "."], in: origin)
        try await git(ident + ["commit", "-q", "-m", "add clash.txt"], in: origin)
        try await git(["fetch", "-q", "origin", "devel"], in: checkout)
        try write("my own file\n", to: "clash.txt", in: checkout)

        let said = Lines()
        let moved = try await within("moveToNewHistory") {
            await Updater.moveToNewHistory(branch: "devel", repoPath: checkout, log: { said.add($0) })
        }

        XCTAssertFalse(moved)
        let head = try await git(["rev-parse", "HEAD"], in: checkout)
        XCTAssertEqual(head, oldHead, "nothing moved")
        let mine = try String(contentsOf: checkout.appendingPathComponent("clash.txt"), encoding: .utf8)
        XCTAssertEqual(mine, "my own file\n", "the untracked file is untouched")
        XCTAssertTrue(said.all.contains { $0.contains("nothing was changed") }, "\(said.all)")
    }
}

/// Log lines collected from a concurrently-called closure.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct StepTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out: \(what)" }
}

/// True for the first caller only: whichever finishes first, the step or its
/// deadline, resumes the continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
