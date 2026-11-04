import Foundation

/// The page's way to open another PsyNeuView window (PsyNeuView#172): a
/// walkthrough stays on its step in one window while the learner opens something
/// else in a second. WKWebView ignores `window.open`, so the page posts
/// `{url}` to `window.webkit.messageHandlers.pnvOpenWindow` instead. No reply.
///
/// The page checks for this handler, and doesn't offer the choice without it.
enum WindowBridge {
    static let handlerName = "pnvOpenWindow"

    /// The address to open, or nil unless the message came from a page's main
    /// frame and the address is on that page's own origin. The window it opens
    /// gets every bridge, so nothing else may ask for one.
    static func allowedURL(body: Any, isMainFrame: Bool, page: URL?) -> URL? {
        guard isMainFrame, let page,
              let fields = body as? [String: Any],
              let text = fields["url"] as? String,
              let url = URL(string: text),
              url.scheme == page.scheme, url.host == page.host, url.port == page.port
        else { return nil }
        return url
    }
}
