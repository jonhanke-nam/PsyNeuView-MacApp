import Foundation

/// Whether a launch should leave a PsyNeuView checkout that is older than the
/// PsyNeuView included with the app (#16).
///
/// App updates replace only the included copy. A Mac set to run a checkout
/// went on running it after the update: one updated to 0.6.1 and still saw
/// PsyNeuView 0.5.16, with nothing on screen to say why. PsyNeuView is part of
/// the app, so an update has to show. A checkout at or past the included
/// version is someone developing PsyNeuView, and is theirs to run.
///
/// PsyNeuLink checkouts are a different matter and are never touched (#9).
///
/// Pure, so the rule is testable without a disk; `declaredVersion(atCheckout:)`
/// is the one part that reads one.
enum OlderCheckout {

    enum Decision: Equatable {
        /// Run the checkout.
        case stay
        /// The app was just updated: switch to the included copy, and say so.
        case switchNow(to: String, from: String)
        /// The checkout was picked since the update: ask, with a one-click switch.
        case offer(to: String, from: String)
    }

    /// - Parameters:
    ///   - isCheckout: the install in use is a checkout, not an included copy.
    ///   - checkoutVersion: the version the checkout declares, if readable.
    ///   - archiveVersion: the version of PsyNeuView included with this app.
    ///   - includedVersionSeen: the included version at the last launch.
    ///   - keptFor: the included version "Keep My Checkout" was chosen for.
    static func decide(
        isCheckout: Bool,
        checkoutVersion: String?,
        archiveVersion: String?,
        includedVersionSeen: String,
        keptFor: String
    ) -> Decision {
        guard isCheckout, let archiveVersion, let checkoutVersion else { return .stay }
        // Only older. Unreadable versions stay too: a checkout is never moved
        // on a guess.
        guard AppUpdateWatch.compare(checkoutVersion, archiveVersion) == .orderedAscending else {
            return .stay
        }
        // A new included version since the last launch is an app update. So is
        // the first launch that records one, which is the update bringing this.
        if includedVersionSeen != archiveVersion {
            return .switchNow(to: archiveVersion, from: checkoutVersion)
        }
        if keptFor == archiveVersion { return .stay }
        return .offer(to: archiveVersion, from: checkoutVersion)
    }

    /// `__version__ = "0.6.1"` in `backend/app/__init__.py`.
    static func declaredVersion(fromInit text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("__version__") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The version a checkout declares, or nil if it can't be read.
    static func declaredVersion(atCheckout url: URL) -> String? {
        let file = url.appendingPathComponent("backend/app/__init__.py")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return declaredVersion(fromInit: text)
    }

    /// Shown while the app switches after an update.
    static func switchedNotice(to: String, from: String) -> String {
        "Updated to PsyNeuView \(to). You were running your checkout (\(from)); "
            + "it's still there, and you can switch back in Settings ▸ Developer."
    }

    /// The question when an older checkout is in use outside an update.
    static func offerText(to: String, from: String) -> (title: String, detail: String) {
        ("Your PsyNeuView checkout is older than this app's",
         "You're running your checkout (\(from)). This app includes PsyNeuView \(to). "
            + "Switching keeps your checkout where it is; you can switch back in "
            + "Settings ▸ Developer.")
    }
}
