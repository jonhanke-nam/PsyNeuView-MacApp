import Foundation

/// The Setup Wizard's words, kept out of the view so they can be tested (#191).
///
/// The welcome list described the old install (developer tools, Node.js, a
/// GitHub sign-in in the browser) even when the app installs the PsyNeuView it
/// carries, which needs none of them, while the footer said the opposite. And
/// nothing said which PsyNeuLink choices give you files you can edit.
enum WizardText {
    struct Step: Equatable {
        let icon: String
        let text: String
    }

    /// What setup will actually do.
    static func steps(bundled: Bool) -> [Step] {
        if bundled {
            return [
                Step(icon: "shippingbox", text: "Setting up Python"),
                Step(icon: "app.badge.checkmark", text: "Installing PsyNeuView (included in this app)"),
                Step(icon: "arrow.down.circle", text: "Installing PsyNeuLink (your choice below)"),
            ]
        }
        return [
            Step(icon: "wrench", text: "Installing developer tools if needed"),
            Step(icon: "shippingbox", text: "Setting up Python and Node.js"),
            Step(icon: "person.badge.key", text: "Connecting to GitHub (opens your browser)"),
            Step(icon: "arrow.down.circle", text: "Downloading and building PsyNeuView"),
        ]
    }
}

extension PsyNeuLinkChoice {
    /// The radio-button label. Editable choices say so.
    var label: String {
        switch self {
        case .github: return "Latest development version"
        case .pypi: return "Official release (PyPI)"
        case .existing: return "A checkout I already have (editable)"
        case .clone: return "Clone a new checkout (editable)"
        }
    }

    /// One line under the choices, for the one selected.
    var explanation: String {
        switch self {
        case .github:
            return "PsyNeuLink's newest code from GitHub. Installed and kept up to date for you; not for editing."
        case .pypi:
            return "The current published release. Installed for you; not for editing."
        case .existing:
            return "Your own PsyNeuLink folder, used in place. Edit it in your IDE and PsyNeuView picks up the changes."
        case .clone:
            return "Makes a new editable copy in a folder you choose. Needs git and an internet connection."
        }
    }

    /// Whether you can edit PsyNeuLink's files with this choice.
    var isEditable: Bool { self == .existing || self == .clone }
}
