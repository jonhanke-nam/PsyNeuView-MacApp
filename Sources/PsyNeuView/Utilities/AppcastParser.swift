import Foundation

/// Minimal reader for the two fields the self-check needs from a Sparkle appcast:
/// the newest release's version and its download (enclosure) URL.
///
/// The appcast lists the newest `<item>` first, so a forward scan lands on the
/// current release. Kept pure and dependency-free (no network, no AppKit) so it
/// can be unit-tested — in particular to guard that the enclosure resolves to a
/// publicly downloadable asset (see #52).
enum AppcastParser {
    /// The newest item's version and enclosure URL, or `nil` if either is absent.
    static func latest(fromXML xml: String) -> (version: String, enclosureURL: String)? {
        guard let version = between(xml, "<sparkle:version>", "</sparkle:version>"),
              !version.isEmpty,
              let url = attribute(xml, tag: "enclosure", named: "url"),
              !url.isEmpty else { return nil }
        return (version, url)
    }

    /// Text between the first `open` marker and the next `close` marker, trimmed.
    static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let o = text.range(of: open),
              let c = text.range(of: close, range: o.upperBound..<text.endIndex) else { return nil }
        return String(text[o.upperBound..<c.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Value of `attr="…"` on the first `<tag …>` element.
    static func attribute(_ text: String, tag: String, named attr: String) -> String? {
        guard let t = text.range(of: "<\(tag)") else { return nil }
        let rest = text[t.upperBound...]
        guard let a = rest.range(of: "\(attr)=\"") else { return nil }
        let after = rest[a.upperBound...]
        guard let end = after.range(of: "\"") else { return nil }
        return String(after[..<end.lowerBound])
    }
}
