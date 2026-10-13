import Foundation
import XCTest
@testable import PsyNeuView
#if canImport(Darwin)
import Darwin
#endif

/// The backend's port is the one from last time when it is free (#218), so
/// the page keeps its origin and so its localStorage across launches.
final class PortChoiceTests: XCTestCase {

    private func choose(remembered: Int?, free: Bool) -> (port: Int, askedFree: [Int], fellBack: Bool) {
        var asked: [Int] = []
        var fellBack = false
        let port = PortChecker.choosePort(
            remembered: remembered,
            isFree: { asked.append($0); return free },
            findFree: { fellBack = true; return 50_001 })
        return (port, asked, fellBack)
    }

    func testRememberedPortIsPreferredWhenFree() {
        let r = choose(remembered: 46_711, free: true)
        XCTAssertEqual(r.port, 46_711)
        XCTAssertEqual(r.askedFree, [46_711])
        XCTAssertFalse(r.fellBack)
    }

    func testRememberedPortInUseFallsBackToAFreeOne() {
        let r = choose(remembered: 46_711, free: false)
        XCTAssertEqual(r.port, 50_001)
        XCTAssertEqual(r.askedFree, [46_711])
        XCTAssertTrue(r.fellBack)
    }

    func testNothingRememberedFindsAFreeOneWithoutAsking() {
        let r = choose(remembered: nil, free: true)
        XCTAssertEqual(r.port, 50_001)
        XCTAssertEqual(r.askedFree, [])
    }

    func testRememberedPortOutOfRangeIsIgnored() {
        for bad in [0, -1, 80, 1023, 65_536, 1_000_000] {
            let r = choose(remembered: bad, free: true)
            XCTAssertEqual(r.port, 50_001, "\(bad)")
            XCTAssertEqual(r.askedFree, [], "\(bad) should never be bind-tested")
        }
        XCTAssertEqual(choose(remembered: 1024, free: true).port, 1024)
        XCTAssertEqual(choose(remembered: 65_535, free: true).port, 65_535)
    }

    // MARK: Remembering

    func testRememberedPortRoundTripsThroughDefaults() {
        let suite = "PortChoiceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(PortChecker.rememberedPort(in: defaults))
        PortChecker.remember(46_711, in: defaults)
        XCTAssertEqual(PortChecker.rememberedPort(in: defaults), 46_711)
        defaults.set(0, forKey: PortChecker.lastPortKey)
        XCTAssertNil(PortChecker.rememberedPort(in: defaults))
        defaults.set("junk", forKey: PortChecker.lastPortKey)
        XCTAssertNil(PortChecker.rememberedPort(in: defaults))
    }

    // MARK: The bind test, for real

    /// A listening socket on a free loopback port; closed by the caller.
    private func listen() throws -> (fd: Int32, port: Int) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(sock, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(sock, 1), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        XCTAssertEqual(named, 0)
        return (sock, Int(UInt16(bigEndian: addr.sin_port)))
    }

    func testIsFreeSeesAListeningSocket() throws {
        let (fd, port) = try listen()
        XCTAssertFalse(PortChecker.isFree(port), "port \(port) has a listener")
        close(fd)
        XCTAssertTrue(PortChecker.isFree(port), "port \(port) was just released")
    }

    func testIsFreeRefusesPortsOutOfRange() {
        XCTAssertFalse(PortChecker.isFree(0))
        XCTAssertFalse(PortChecker.isFree(70_000))
    }

    func testFreshPortIsFree() {
        let port = PortChecker.findFreePort()
        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(PortChecker.isFree(port))
    }
}
