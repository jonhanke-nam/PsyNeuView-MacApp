import XCTest
@testable import PsyNeuView

final class ServerStatusTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(ServerStatus.stopped.displayName, "Stopped")
        XCTAssertEqual(ServerStatus.running.displayName, "Running")
        XCTAssertEqual(ServerStatus.error.displayName, "Error")
    }
}

final class LogEntryTests: XCTestCase {
    func testCreation() {
        let entry = LogEntry(source: .backend, text: "test message")
        XCTAssertEqual(entry.source, .backend)
        XCTAssertEqual(entry.text, "test message")
        XCTAssertFalse(entry.isError)
    }

    func testErrorEntry() {
        let entry = LogEntry(source: .system, text: "error msg", isError: true)
        XCTAssertTrue(entry.isError)
        XCTAssertEqual(entry.source, .system)
    }
}
