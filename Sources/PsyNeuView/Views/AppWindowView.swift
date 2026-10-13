import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A SwiftUI view that embeds a WKWebView to display the PsyNeuView frontend.
/// This makes the app self-contained — no external browser needed.
struct AppWindowView: NSViewRepresentable {
    let url: URL
    /// The app's side of the `pnvSettings` bridge (#200). Nil leaves the
    /// bridge out, and the page shows no Mac app section.
    var settingsHost: AppSettingsHost? = nil
    /// Open PsyNeuView's Settings once the page has loaded: ⌘, pressed while
    /// no app window was open (#200).
    var openSettingsOnLoad = false
    /// The app's store of the page's own preferences (#218). Nil leaves the
    /// page's `localStorage` alone, as before.
    var pagePreferences: PagePreferencesStore? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Allow localhost network access
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // File bridge: the frontend's Open / Save-As flows need real absolute
        // filesystem paths (the backend operates on paths on disk), which
        // <input type="file"> can never provide inside WKWebView, and its
        // Show in Finder buttons need Finder. The frontend capability-detects
        // window.webkit.messageHandlers.pnvFile and falls back to typed-path
        // prompts on plain web. postMessage returns a Promise that resolves
        // with the reply object; see FileBridge for the contract.
        config.userContentController.addScriptMessageHandler(
            context.coordinator, contentWorld: .page, name: FileBridge.handlerName)
        // Settings bridge (#200): the Mac app section of PsyNeuView's Settings
        // reads and writes the app's own settings through this. Same reply
        // pattern as pnvFile; see SettingsBridge for the contract.
        if settingsHost != nil {
            config.userContentController.addScriptMessageHandler(
                context.coordinator, contentWorld: .page, name: SettingsBridge.handlerName)
        }
        // Page preferences (#218): before the page's own scripts run, seed
        // its localStorage with what the app kept (keys the page hasn't set
        // on this origin only), and have every later change to a PsyNeuView
        // key posted back as a pnvPrefs message. In the page's world, since
        // the page's own localStorage calls are what it wraps; main frame
        // only; no reply. See PagePreferences for the contract.
        if let store = pagePreferences {
            config.userContentController.addUserScript(WKUserScript(
                source: PagePreferences.userScript(seeding: store.entries),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
            config.userContentController.add(
                context.coordinator, contentWorld: .page, name: PagePreferences.handlerName)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) PsyNeuView/1.0"

        // Allow the web view to be inspected via Safari dev tools
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        // View ▸ Zoom (#178). Every open window follows the one stored level.
        //
        // Pinch stays off (`allowsMagnification`) on purpose: WKWebView would
        // take the pinch gesture for itself, and the graph canvas already uses
        // pinch to zoom the graph.
        webView.pageZoom = WindowZoom.stored()
        context.coordinator.observeZoom(of: webView)
        context.coordinator.observeSettings(of: webView, openOnLoad: openSettingsOnLoad)

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if the URL actually changed
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(settingsHost: settingsHost, pagePreferences: pagePreferences)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
        WKScriptMessageHandlerWithReply, WKScriptMessageHandler
    {
        private weak var zoomedView: WKWebView?

        /// A file panel that is currently on screen.
        ///
        /// `NSOpenPanel.begin` presents a free-floating, modeless panel. Nothing
        /// stops a second call presenting another on top, and because they are
        /// not attached to the window there is no way to tell how many are
        /// stacked — dismissing one reveals the next, which reads as dialogs
        /// reopening themselves. Both panel paths here, the JS bridge and
        /// WKWebView's file input, go through this, so one cannot stack on the
        /// other either.
        private weak var filePanel: NSSavePanel?
        private var zoomObserver: NSObjectProtocol?
        private let settingsHost: AppSettingsHost?
        private var settingsObservers: [NSObjectProtocol] = []
        /// Whether the page has finished loading. ⌘, before then is held in
        /// `openSettingsPending` and delivered when it has (#200).
        private var pageLoaded = false
        private var openSettingsPending = false
        private let pagePreferences: PagePreferencesStore?

        init(settingsHost: AppSettingsHost?, pagePreferences: PagePreferencesStore?) {
            self.settingsHost = settingsHost
            self.pagePreferences = pagePreferences
        }

        // MARK: pnvPrefs (#218)

        /// A change the page made to one of its own localStorage keys. No
        /// reply: the page has already made the change; this only keeps it.
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == PagePreferences.handlerName, let store = pagePreferences else { return }
            let body = message.body
            MainActor.assumeIsolated {
                store.receive(body)
            }
        }

        func observeZoom(of webView: WKWebView) {
            zoomedView = webView
            zoomObserver = NotificationCenter.default.addObserver(
                forName: WindowZoom.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.zoomedView?.pageZoom = WindowZoom.stored()
            }
        }

        deinit {
            if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
            for observer in settingsObservers { NotificationCenter.default.removeObserver(observer) }
        }

        // MARK: Settings (#200)

        /// Follow ⌘, for this window, and changes made from any window.
        func observeSettings(of webView: WKWebView, openOnLoad: Bool) {
            openSettingsPending = openOnLoad
            let center = NotificationCenter.default
            settingsObservers.append(center.addObserver(
                forName: SettingsBridge.openRequested, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let view = self.zoomedView,
                      note.object == nil || (note.object as? NSWindow) === view.window
                else { return }
                self.openSettings()
            })
            guard settingsHost != nil else { return }
            settingsObservers.append(center.addObserver(
                forName: SettingsBridge.didChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, self.pageLoaded,
                      let snapshot = note.userInfo?["snapshot"] as? [String: Any] else { return }
                self.zoomedView?.evaluateJavaScript(
                    SettingsBridge.eventScript(SettingsBridge.changedEvent, detail: snapshot),
                    completionHandler: nil)
            })
        }

        /// Ask the page to open Settings, now or once it has loaded.
        func openSettings() {
            guard pageLoaded, let view = zoomedView, !view.isLoading else {
                openSettingsPending = true
                return
            }
            openSettingsPending = false
            view.evaluateJavaScript(SettingsBridge.openSettingsScript, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            pageLoaded = false
        }

        private func handleSettingsMessage(
            _ body: Any, _ replyHandler: @escaping (Any?, String?) -> Void
        ) {
            guard let host = settingsHost else {
                replyHandler(nil, "pnvSettings: not available")
                return
            }
            MainActor.assumeIsolated {
                let outcome = SettingsBridge.handle(body, host: host)
                switch outcome.reply {
                case .success(let reply):
                    replyHandler(reply, nil)
                case .failure(let failure):
                    replyHandler(nil, failure.message)
                }
                if let body = body as? [String: Any], body["op"] as? String == "set",
                   case .success = outcome.reply {
                    NotificationCenter.default.post(
                        name: SettingsBridge.didChange, object: nil,
                        userInfo: ["snapshot": SettingsBridge.snapshot(host)])
                }
                if let decision = outcome.switchTo {
                    // After the reply: switching closes this window.
                    Task { @MainActor in host.switchInstall(decision) }
                }
            }
        }

        // MARK: pnvFile bridge (jonhanke-nam/PsyNeuView-MacApp#28)
        //
        // The JS contract (open, saveAs, reveal) is documented on FileBridge.
        // The two panels are UI, so they stay here; reveal's decisions are
        // FileBridge's, and only the Finder call is made here.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            if message.name == SettingsBridge.handlerName {
                handleSettingsMessage(message.body, replyHandler)
                return
            }
            guard
                let body = message.body as? [String: Any],
                let op = body["op"] as? String
            else {
                replyHandler(nil, "pnvFile: message must be an object with an 'op' field")
                return
            }
            switch op {
            case "open":
                runBridgeOpenPanel(body, replyHandler)
            case "saveAs":
                runBridgeSavePanel(body, replyHandler)
            case "reveal":
                revealInFinder(body, replyHandler)
            default:
                replyHandler(nil, "pnvFile: unknown op '\(op)'")
            }
        }

        /// Show in Finder (jonhanke-nam/PsyNeuView-archive#1295): select the file or
        /// folder in its parent folder. The reply goes back after Finder has
        /// been asked, so the page never shows a success Finder didn't get.
        private func revealInFinder(
            _ body: [String: Any], _ replyHandler: @escaping (Any?, String?) -> Void
        ) {
            let outcome = FileBridge.handleReveal(body: body) { path in
                FileManager.default.fileExists(atPath: path)
            }
            switch outcome.reply {
            case .success(let reply):
                if let url = outcome.reveal {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                replyHandler(reply, nil)
            case .failure(let failure):
                replyHandler(nil, failure.message)
            }
        }

        private func contentTypes(from body: [String: Any]) -> [UTType]? {
            guard let exts = body["extensions"] as? [String], !exts.isEmpty else { return nil }
            let types = exts.compactMap { UTType(filenameExtension: $0.lowercased()) }
            return types.isEmpty ? nil : types
        }

        private func defaultDirectoryURL(from body: [String: Any]) -> URL? {
            guard let dir = body["defaultDir"] as? String, !dir.isEmpty else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: dir, isDirectory: true)
        }

        private func runBridgeOpenPanel(
            _ body: [String: Any], _ replyHandler: @escaping (Any?, String?) -> Void
        ) {
            let panel = NSOpenPanel()
            let wantsDirectories = body["directories"] as? Bool ?? false
            panel.canChooseFiles = !wantsDirectories
            panel.canChooseDirectories = wantsDirectories
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = wantsDirectories
            if let message = body["message"] as? String { panel.message = message }
            if let types = contentTypes(from: body) { panel.allowedContentTypes = types }
            if let dir = defaultDirectoryURL(from: body) { panel.directoryURL = dir }

            // Already asking? Bring that panel forward instead of stacking a
            // second one, and answer this request straight away — leaving the
            // promise unresolved would hang the caller.
            if let existing = filePanel {
                existing.makeKeyAndOrderFront(nil)
                replyHandler(["path": NSNull()] as [String: Any], nil)
                return
            }
            filePanel = panel
            presentFilePanel(panel) { [weak self] response in
                self?.filePanel = nil
                let path = (response == .OK) ? panel.url?.path : nil
                replyHandler(["path": path ?? NSNull()] as [String: Any], nil)
            }
        }

        /// Show a panel as a sheet on the app window where there is one, so it
        /// is visually attached and window-modal rather than another floating
        /// window to find. Falls back to `begin` if no window is available.
        private func presentFilePanel(
            _ panel: NSSavePanel,
            _ done: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            if let window = zoomedView?.window ?? NSApp.windows.first(where: { $0.isVisible }) {
                panel.beginSheetModal(for: window, completionHandler: done)
            } else {
                panel.begin(completionHandler: done)
            }
        }

        private func runBridgeSavePanel(
            _ body: [String: Any], _ replyHandler: @escaping (Any?, String?) -> Void
        ) {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            if let message = body["message"] as? String { panel.message = message }
            if let name = body["defaultName"] as? String, !name.isEmpty {
                panel.nameFieldStringValue = name
            }
            if let types = contentTypes(from: body) {
                panel.allowedContentTypes = types
                // The frontend appends multi-part extensions like .mdf.yaml
                // itself; don't let the panel rewrite them.
                panel.allowsOtherFileTypes = true
            }
            if let dir = defaultDirectoryURL(from: body) { panel.directoryURL = dir }

            panel.begin { response in
                let path = (response == .OK) ? panel.url?.path : nil
                replyHandler(["path": path ?? NSNull()] as [String: Any], nil)
            }
        }

        // WKWebView swallows clicks on hidden <input type="file"> unless the host
        // app surfaces a native picker via this delegate method. Frontend features
        // like Toolbar → Import MDF... rely on it.
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canCreateDirectories = false

            if let existing = filePanel {
                existing.makeKeyAndOrderFront(nil)
                completionHandler(nil)
                return
            }
            filePanel = panel
            presentFilePanel(panel) { [weak self] response in
                self?.filePanel = nil
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        // The page's alert(), confirm() and prompt() (#243). WKWebView shows
        // none of them without these: confirm() answered false at once, so
        // "You have unsaved changes… Load anyway?" cancelled every open with
        // nothing on screen. Each completion handler is called exactly once.
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = pageAlert(message, buttons: PageDialogs.alertButtons)
            presentPageAlert(alert, in: webView) { _ in completionHandler() }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = pageAlert(message, buttons: PageDialogs.confirmButtons)
            presentPageAlert(alert, in: webView) { response in
                completionHandler(PageDialogs.confirmResult(pressedFirstButton: response == .alertFirstButtonReturn))
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = pageAlert(prompt, buttons: PageDialogs.confirmButtons)
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            presentPageAlert(alert, in: webView) { response in
                completionHandler(PageDialogs.promptResult(
                    pressedFirstButton: response == .alertFirstButtonReturn,
                    text: field.stringValue
                ))
            }
        }

        private func pageAlert(_ message: String, buttons: [String]) -> NSAlert {
            let alert = NSAlert()
            alert.messageText = PageDialogs.title
            alert.informativeText = message
            for title in buttons { alert.addButton(withTitle: title) }
            return alert
        }

        /// As a sheet on the app window, or on its own when the page has no
        /// window yet.
        private func presentPageAlert(
            _ alert: NSAlert, in webView: WKWebView,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }

        /// System Settings links (`x-apple.systempreferences:`) open in macOS;
        /// everything else loads as before. See SystemSettingsLinks.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url, SystemSettingsLinks.opensInSystemSettings(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if openSettingsPending {
                openSettingsPending = false
                webView.evaluateJavaScript(SettingsBridge.openSettingsScript, completionHandler: nil)
            }
            // After the page loads, inject a script that retries the demos fetch.
            // The frontend's initial fetch may have failed silently if the backend
            // warm worker wasn't ready yet. This retry ensures demos load.
            let retryScript = """
            (function() {
                // Wait a moment for React to mount, then retry demos fetch
                setTimeout(function() {
                    fetch('/api/demos')
                        .then(function(r) { return r.json(); })
                        .then(function(data) {
                            if (data.demos && data.demos.length > 0) {
                                // Demos are available — reload the page to pick them up
                                // since we can't directly update React state from here
                                if (document.querySelector('[data-no-demos]') ||
                                    document.body.innerText.includes('No demos found')) {
                                    window.location.reload();
                                }
                            }
                        })
                        .catch(function() {
                            // Backend not ready yet, try again in 3 seconds
                            setTimeout(function() { window.location.reload(); }, 3000);
                        });
                }, 2000);
            })();
            """
            webView.evaluateJavaScript(retryScript, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Retry on failure — the frontend may not be ready yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let url = webView.url {
                    webView.load(URLRequest(url: url))
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Retry on provisional failure — common during startup
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let url = webView.url {
                    webView.load(URLRequest(url: url))
                }
            }
        }
    }
}
