import AppKit
import SwiftUI

/// The About window (#128).
///
/// macOS's `orderFrontStandardAboutPanel` gives you the icon, name and
/// copyright layout for free, but it is a system window: fixed size, no
/// magnification gesture, and nothing you pass in changes either. Wanting the
/// text bigger, and wanting to pinch it bigger, meant owning the window.
///
/// What that costs is exactly the part macOS was doing for us — the icon,
/// name and version have to be laid out here and kept in step with Info.plist.
/// The version *content* is unaffected: it still comes from
/// `VersionReport.aboutLines(...)`.
struct AboutView: View {
    let lines: [String]

    /// Remembered across launches, so someone who needs larger text sets it
    /// once rather than every time they open the window.
    @AppStorage(AboutWindowController.scaleKey) private var scale: Double = 1.0


    /// Live pinch amount, folded into `scale` when the gesture ends. Kept
    /// separate so an in-progress pinch can be abandoned without writing a
    /// half-finished value to preferences.
    @State private var pinch: CGFloat = 1.0

    private static let minScale = 0.8
    private static let maxScale = 3.0

    private var effective: CGFloat {
        clamp(CGFloat(scale) * pinch)
    }

    private func clamp(_ v: CGFloat) -> CGFloat {
        min(max(v, CGFloat(Self.minScale)), CGFloat(Self.maxScale))
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage()
    }

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? AppIdentity.current.displayName
    }

    private var copyright: String? {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14 * effective) {
                HStack(alignment: .center, spacing: 14 * effective) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 64 * effective, height: 64 * effective)
                    Text(appName)
                        .font(.system(size: 22 * effective, weight: .semibold))
                }

                // The version report, one line each. Selectable because these
                // are the lines people are asked to paste into a bug report.
                VStack(alignment: .leading, spacing: 4 * effective) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 13 * effective))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let copyright {
                    Text(copyright)
                        .font(.system(size: 11 * effective))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(20 * effective)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .gesture(
            MagnificationGesture()
                .onChanged { pinch = $0 }
                .onEnded { value in
                    scale = Double(clamp(CGFloat(scale) * value))
                    pinch = 1.0
                }
        )
    }

    private func bump(_ factor: CGFloat) {
        scale = Double(clamp(CGFloat(scale) * factor))
    }
}

/// Zoom steps, shared by the key handler and anything else that adjusts size.
///
/// Kept out of the view so the arithmetic is testable and so the window can
/// drive it from an AppKit key monitor — SwiftUI's `.keyboardShortcut` did not
/// register on the hidden zero-sized buttons this first used, which is how the
/// shortcuts came to do nothing at all (#128).
enum AboutZoom {
    static let minScale = 0.8
    static let maxScale = 3.0
    static let step = 1.15

    static func clamp(_ v: Double) -> Double { min(max(v, minScale), maxScale) }
    static func zoomedIn(_ v: Double) -> Double { clamp(v * step) }
    static func zoomedOut(_ v: Double) -> Double { clamp(v / step) }
    static let reset = 1.0
}

/// Owns the single About window, so repeated About clicks raise the existing
/// one rather than stacking copies.
final class AboutWindowController {
    static let scaleKey = "aboutFontScale"

    private var window: NSWindow?
    /// Removed when the window closes; a monitor that outlives its window would
    /// keep swallowing ⌘+ for the rest of the session.
    private var keyMonitor: Any?

    func show(lines: [String]) {
        if let window {
            // Rebuild the content: versions can change while the app runs (a
            // different PsyNeuLink source, a reinstall), and a stale About
            // window is worse than none.
            window.contentView = NSHostingView(rootView: AboutView(lines: lines))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Native on purpose (PsyNeuView-archive#1279): versions even when the server is down.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: AboutView(lines: lines))
        window.title = "About \(AppIdentity.current.displayName)"
        window.isReleasedWhenClosed = false
        // Remembers size and position between launches, which is half of what
        // "make it adjustable" means in practice.
        window.setFrameAutosaveName("AboutWindow")
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        installKeyMonitor(for: window)
    }

    /// ⌘+ / ⌘- / ⌘0, handled in AppKit.
    ///
    /// The first version put these on SwiftUI buttons hidden with `.opacity(0)`
    /// and a zero frame. It compiled, and the shortcuts did nothing — hidden
    /// zero-sized buttons do not reliably register a `.keyboardShortcut`. Only
    /// pressing the keys in a real build showed it.
    ///
    /// Local monitor rather than menu items on purpose: these belong to this
    /// window. In the main menu they would claim ⌘+ and ⌘- application-wide,
    /// where the web view already means something by them.
    private func installKeyMonitor(for window: NSWindow) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, window.isKeyWindow,
                  event.modifierFlags.contains(.command) else { return event }

            let defaults = UserDefaults.standard
            let current = defaults.object(forKey: AboutWindowController.scaleKey) as? Double ?? 1.0

            switch event.charactersIgnoringModifiers {
            case "+", "=":
                defaults.set(AboutZoom.zoomedIn(current), forKey: AboutWindowController.scaleKey)
                return nil
            case "-":
                defaults.set(AboutZoom.zoomedOut(current), forKey: AboutWindowController.scaleKey)
                return nil
            case "0":
                defaults.set(AboutZoom.reset, forKey: AboutWindowController.scaleKey)
                return nil
            default:
                return event
            }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
