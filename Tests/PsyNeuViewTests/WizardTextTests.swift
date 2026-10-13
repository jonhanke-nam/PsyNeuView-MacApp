import XCTest
@testable import PsyNeuView

/// The Setup Wizard says what will actually happen, and which choices are editable (#191).
final class WizardTextTests: XCTestCase {

    func testTheBundledInstallMentionsNoDeveloperToolsNodeOrGitHub() {
        let text = WizardText.steps(bundled: true).map(\.text).joined(separator: " ")
        XCTAssertFalse(text.contains("developer tools"))
        XCTAssertFalse(text.contains("Node.js"))
        XCTAssertFalse(text.contains("GitHub"))
        XCTAssertTrue(text.contains("included in this app"))
    }

    func testTheCloneInstallStillListsWhatItNeeds() {
        let text = WizardText.steps(bundled: false).map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("GitHub"))
        XCTAssertTrue(text.contains("Node.js"))
    }

    func testOnlyLocalCheckoutsAreEditable() {
        XCTAssertTrue(PsyNeuLinkChoice.existing.isEditable)
        XCTAssertTrue(PsyNeuLinkChoice.clone.isEditable)
        XCTAssertFalse(PsyNeuLinkChoice.github.isEditable)
        XCTAssertFalse(PsyNeuLinkChoice.pypi.isEditable)
    }

    func testEachChoiceSaysWhetherItCanBeEdited() {
        for choice in [PsyNeuLinkChoice.github, .pypi, .existing, .clone] {
            let says = choice.explanation.lowercased()
            if choice.isEditable {
                XCTAssertTrue(says.contains("edit"), "\(choice) should say it's editable")
                XCTAssertTrue(choice.label.contains("(editable)"))
            } else {
                XCTAssertTrue(says.contains("not for editing"), "\(choice) should say it isn't for editing")
                XCTAssertFalse(choice.label.contains("editable"))
            }
        }
    }
}
