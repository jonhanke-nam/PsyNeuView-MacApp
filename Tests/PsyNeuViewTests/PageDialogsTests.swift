import XCTest
@testable import PsyNeuView

/// The page's alert(), confirm() and prompt() answer as a browser's do (#243).
final class PageDialogsTests: XCTestCase {

    func testConfirmIsTrueOnlyForOK() {
        XCTAssertTrue(PageDialogs.confirmResult(pressedFirstButton: true))
        XCTAssertFalse(PageDialogs.confirmResult(pressedFirstButton: false))
    }

    func testPromptReturnsTheTextForOKAndNullForCancel() {
        XCTAssertEqual(PageDialogs.promptResult(pressedFirstButton: true, text: "Stroop"), "Stroop")
        XCTAssertEqual(PageDialogs.promptResult(pressedFirstButton: true, text: ""), "")
        XCTAssertNil(PageDialogs.promptResult(pressedFirstButton: false, text: "Stroop"))
    }

    func testOKIsTheDefaultButton() {
        XCTAssertEqual(PageDialogs.alertButtons, ["OK"])
        XCTAssertEqual(PageDialogs.confirmButtons.first, "OK")
        XCTAssertEqual(PageDialogs.confirmButtons.count, 2)
    }
}
