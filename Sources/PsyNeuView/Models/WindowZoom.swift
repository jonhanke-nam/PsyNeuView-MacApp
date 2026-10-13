import Foundation

/// Zoom for the app window's web view: View ▸ Zoom In / Zoom Out / Actual Size (#178).
///
/// Everything in the window is web content — toolbar, panels, the tutorial
/// bar — so `WKWebView.pageZoom` enlarges all of it at once and reflows it,
/// the way ⌘+ does in a browser. The Inspector and code-editor text-size
/// settings inside the app still apply on top.
///
/// Steps rather than a multiplier, matching Safari and Chrome: every level is
/// a round percentage, and in-then-out always lands back where it started.
/// Kept out of the view so the arithmetic is testable, as `AboutZoom` is.
enum WindowZoom {
    static let defaultsKey = "windowPageZoom"
    static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let reset = 1.0
    static var minLevel: Double { levels.first! }
    static var maxLevel: Double { levels.last! }

    /// Posted after the stored level changes, so every open app window follows.
    static let didChange = Notification.Name("PsyNeuViewWindowZoomDidChange")

    static func clamp(_ v: Double) -> Double { min(max(v, minLevel), maxLevel) }

    /// The next level up. A value between levels (a hand-edited preference)
    /// moves to the nearest level above it rather than jumping a whole step.
    static func zoomedIn(_ v: Double) -> Double {
        levels.first { $0 > v + 0.001 } ?? maxLevel
    }

    static func zoomedOut(_ v: Double) -> Double {
        levels.last { $0 < v - 0.001 } ?? minLevel
    }

    /// Remembered across launches: someone who needs larger text sets it once.
    static func stored(in defaults: UserDefaults = .standard) -> Double {
        guard let v = defaults.object(forKey: defaultsKey) as? Double, v > 0 else { return reset }
        return clamp(v)
    }

    static func store(_ v: Double, in defaults: UserDefaults = .standard) {
        defaults.set(clamp(v), forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// "125%", for the menu.
    static func percentLabel(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}
