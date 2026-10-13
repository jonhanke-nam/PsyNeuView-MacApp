import Foundation
import XCTest
@testable import PsyNeuView

/// The app window's zoom steps and remembered level (#178).
final class WindowZoomTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "WindowZoomTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testZoomingInAndOutMoveOneLevel() {
        XCTAssertEqual(WindowZoom.zoomedIn(1.0), 1.1)
        XCTAssertEqual(WindowZoom.zoomedOut(1.0), 0.9)
    }

    func testInThenOutLandsBackWhereItStarted() {
        for level in WindowZoom.levels.dropFirst().dropLast() {
            XCTAssertEqual(WindowZoom.zoomedOut(WindowZoom.zoomedIn(level)), level)
        }
    }

    func testZoomStopsAtBothEnds() {
        // A held key must not run the page to nothing, or off the screen.
        var v = 1.0
        for _ in 0..<50 { v = WindowZoom.zoomedIn(v) }
        XCTAssertEqual(v, WindowZoom.maxLevel)
        for _ in 0..<50 { v = WindowZoom.zoomedOut(v) }
        XCTAssertEqual(v, WindowZoom.minLevel)
        XCTAssertGreaterThan(v, 0)
    }

    func testAnOffStepValueMovesToTheNearestLevel() {
        XCTAssertEqual(WindowZoom.zoomedIn(1.2), 1.25)
        XCTAssertEqual(WindowZoom.zoomedOut(1.2), 1.1)
    }

    func testNothingStoredMeansActualSize() {
        XCTAssertEqual(WindowZoom.stored(in: defaults), WindowZoom.reset)
    }

    func testTheLevelIsRemembered() {
        WindowZoom.store(1.5, in: defaults)
        XCTAssertEqual(WindowZoom.stored(in: defaults), 1.5)
    }

    func testAStoredValueOutOfRangeIsClamped() {
        defaults.set(40.0, forKey: WindowZoom.defaultsKey)
        XCTAssertEqual(WindowZoom.stored(in: defaults), WindowZoom.maxLevel)
        defaults.set(-1.0, forKey: WindowZoom.defaultsKey)
        XCTAssertEqual(WindowZoom.stored(in: defaults), WindowZoom.reset)
    }

    func testStoringTellsOpenWindows() {
        let posted = expectation(forNotification: WindowZoom.didChange, object: nil)
        WindowZoom.store(1.25, in: defaults)
        wait(for: [posted], timeout: 1)
    }

    func testPercentLabel() {
        XCTAssertEqual(WindowZoom.percentLabel(1.25), "125%")
        XCTAssertEqual(WindowZoom.percentLabel(0.67), "67%")
    }
}
