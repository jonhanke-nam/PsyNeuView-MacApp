import Foundation
import XCTest
@testable import PsyNeuView

/// The About window's zoom steps (#128).
///
/// Extracted from the view because the first implementation put the shortcuts
/// on hidden zero-sized SwiftUI buttons: it compiled, and pressing the keys did
/// nothing. Only running a real build showed it. The arithmetic at least can be
/// held in place here.
final class AboutZoomTests: XCTestCase {

    func testZoomingInGrows() {
        XCTAssertGreaterThan(AboutZoom.zoomedIn(1.0), 1.0)
    }

    func testZoomingOutShrinks() {
        XCTAssertLessThan(AboutZoom.zoomedOut(1.0), 1.0)
    }

    func testZoomingInStopsAtAMaximum() {
        // Otherwise a held key runs the text off the window.
        var v = 1.0
        for _ in 0..<50 { v = AboutZoom.zoomedIn(v) }
        XCTAssertEqual(v, AboutZoom.maxScale, accuracy: 0.0001)
    }

    func testZoomingOutStopsAtAMinimum() {
        // And never reaches zero, which would make the window blank.
        var v = 1.0
        for _ in 0..<50 { v = AboutZoom.zoomedOut(v) }
        XCTAssertEqual(v, AboutZoom.minScale, accuracy: 0.0001)
        XCTAssertGreaterThan(v, 0)
    }

    func testResetReturnsToNormal() {
        XCTAssertEqual(AboutZoom.reset, 1.0)
    }

    func testInAndOutAreInverses() {
        // A step in then out should land back where it started, so tapping
        // ⌘+ then ⌘- is not a slow drift.
        XCTAssertEqual(AboutZoom.zoomedOut(AboutZoom.zoomedIn(1.0)), 1.0, accuracy: 0.0001)
    }
}
