import Foundation

/// Dotted-version comparison shared by every version gate in the app.
///
/// Previously duplicated between `DependencyChecker` and `DependencyInstaller`,
/// which is how the two drifted apart (#61). `DependencyChecker` has since been
/// deleted (#77); this is the only version comparator in the app.
enum SemanticVersion {
    /// True when `version` >= `minimum`, comparing numerically component by
    /// component. Missing components count as zero, so "3.12" >= "3.12.0".
    static func isAtLeast(_ version: String, minimum: String) -> Bool {
        let vParts = numericComponents(of: version)
        let mParts = numericComponents(of: minimum)
        for i in 0..<max(vParts.count, mParts.count) {
            let v = i < vParts.count ? vParts[i] : 0
            let m = i < mParts.count ? mParts[i] : 0
            if v > m { return true }
            if v < m { return false }
        }
        return true // equal
    }

    /// True when `version` < `exclusiveBound`.
    static func isBelow(_ version: String, exclusiveBound: String) -> Bool {
        !isAtLeast(version, minimum: exclusiveBound)
    }

    /// Leading numeric components, stopping at the first non-numeric one so
    /// pre-release suffixes like "3.15.0a1" compare as "3.15.0".
    private static func numericComponents(of version: String) -> [Int] {
        var parts: [Int] = []
        for chunk in version.split(separator: ".") {
            let digits = chunk.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parts.append(value)
        }
        return parts
    }
}

/// The Python versions PsyNeuView supports.
///
/// Single source of truth, mirroring `backend/pyproject.toml`'s
/// `requires-python = ">=3.12,<3.15"` and the range PsyNeuView's Makefile
/// enforces. Before this existed the app accepted anything >= 3.9, so a user
/// with 3.9–3.11 on their PATH passed the check, got a venv built from it, and
/// failed much later at `pip install -e .` with a far less legible error. (#61)
///
/// Bundling the interpreter (#64) makes this moot for new installs, but the gate
/// still guards every install until then.
enum PythonRequirement {
    /// Lowest supported version, inclusive.
    static let minimumInclusive = "3.12"

    /// First unsupported version. Matches `<3.15` in pyproject.toml.
    static let maximumExclusive = "3.15"

    /// Homebrew formulae satisfying the range, newest first.
    static let supportedFormulae = ["python@3.14", "python@3.13", "python@3.12"]

    /// The formula to install when no supported Python is present. Pinned
    /// deliberately: plain `brew install python` tracks Homebrew's newest, which
    /// will fall outside the range the day 3.15 ships.
    static let preferredFormula = "python@3.14"

    /// Interpreter names to look for on disk, newest first — mirrors the
    /// Makefile's `PYTHON_SUPPORTED`.
    static let supportedInterpreters = ["python3.14", "python3.13", "python3.12"]

    /// True when `version` falls inside the supported range.
    static func isSupported(_ version: String) -> Bool {
        SemanticVersion.isAtLeast(version, minimum: minimumInclusive)
            && SemanticVersion.isBelow(version, exclusiveBound: maximumExclusive)
    }

    /// Human phrasing of the range, e.g. "3.12, 3.13, or 3.14".
    static var supportedVersionsDescription: String {
        let majors = supportedFormulae
            .compactMap { $0.split(separator: "@").last.map(String.init) }
            .reversed()
        guard let last = majors.last else { return minimumInclusive }
        let leading = majors.dropLast()
        return leading.isEmpty ? last : leading.joined(separator: ", ") + ", or " + last
    }

    /// Explain a rejected interpreter the way the Makefile does: what was found,
    /// what is needed, and — when one is already on the machine — which
    /// interpreter to use instead.
    ///
    /// - Parameters:
    ///   - version: the version that was rejected, e.g. "3.11.9".
    ///   - alternative: a supported interpreter found on this machine, if any.
    static func rejectionMessage(found version: String, alternative: String?) -> String {
        var lines = [
            "Python \(version) is not supported — PsyNeuView needs \(supportedVersionsDescription).",
            "(backend/pyproject.toml: requires-python = \">=\(minimumInclusive),<\(maximumExclusive)\")",
        ]
        if let alternative {
            lines.append("Found \(alternative) on this Mac — using that instead.")
        } else {
            lines.append("Installing \(preferredFormula).")
        }
        return lines.joined(separator: "\n")
    }
}
