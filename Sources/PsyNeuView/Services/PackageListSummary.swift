import Foundation

/// One Logs-window row in place of uv's package list (#75).
///
/// After an install uv lists every package it changed, one per line:
/// ` + numpy==2.1.0`, ` - numpy==2.0.0`, ` ~ psyneulink==0.19.1 (from …)`.
/// A fresh environment is a couple of hundred of them, which buried
/// everything else in the window. A run of such lines becomes one row that
/// counts them; the launch log, which Report a Problem attaches, keeps every
/// line.
struct PackageListSummary: Equatable {
    private(set) var installed = 0
    private(set) var removed = 0

    /// The change a line records: `+` added, `-` removed, `~` reinstalled.
    /// Nil for any other line.
    static func change(in line: String) -> Character? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let mark = trimmed.first, "+-~".contains(mark) else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.first == " " else { return nil }
        let spec = rest.dropFirst()
        // A package name, then a pinned version or a direct reference:
        // `name==1.2`, `name[extra]==1.2`, `name @ git+https://…`.
        guard let first = spec.first, first.isLetter || first.isNumber else { return nil }
        guard let end = spec.firstIndex(where: { $0 == "=" || $0 == " " }) else { return nil }
        let name = spec[..<end]
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "._-[],".contains($0) }) else { return nil }
        let after = spec[end...]
        if after.hasPrefix("=="), after.count > 2 { return mark }
        if after.hasPrefix(" @ "), after.count > 3 { return mark }
        return nil
    }

    /// Count `line` if it is a package line. False, and nothing counted,
    /// for any other line.
    mutating func absorb(_ line: String) -> Bool {
        switch Self.change(in: line) {
        case "+", "~": installed += 1
        case "-": removed += 1
        default: return false
        }
        return true
    }

    var isEmpty: Bool { installed == 0 && removed == 0 }

    /// The row's text: "Installed 214 packages", "Removed 2 packages",
    /// "Installed 3 packages, removed 2".
    var text: String {
        func packages(_ n: Int) -> String { n == 1 ? "1 package" : "\(n) packages" }
        var parts: [String] = []
        if installed > 0 { parts.append("Installed \(packages(installed))") }
        if removed > 0 { parts.append(installed > 0 ? "removed \(removed)" : "Removed \(packages(removed))") }
        return parts.joined(separator: ", ") + " (each one is in the launch log)"
    }
}
