import AppKit
import Observation
import UniformTypeIdentifiers

/// The Report a Problem screen's state and actions (#202).
///
/// The screen lives in the Logs window (PsyNeuView-archive#1279: Logs is one of the
/// allowed native windows, and must work when PsyNeuView itself won't
/// start, which is when people most need to report). Help ▸ Report a
/// Problem…, the Logs window's button and the failed starting window's button
/// all call `AppDelegate.showReportProblem`, which opens it here.
@MainActor
@Observable
final class ProblemReportModel {

    struct Shot: Identifiable {
        let id = UUID()
        var image: NSImage
        var png: Data
        /// "The app window", or the added file's name.
        var source: String
        var included = true
    }

    var isOpen = false
    var whatHappened = ""
    var expected = ""
    var included: Set<ProblemReport.Part> = Set(ProblemReport.Part.allCases)
    var shots: [Shot] = []
    /// Why there's no app-window screenshot, when there isn't one.
    var screenshotNote: String?
    var saved: ReportWriter.Saved?
    /// The report as saved, for the send buttons.
    var savedRequest: ProblemReport.Request?
    var error: String?
    /// Brief confirmation after Copy summary.
    var copiedSummary = false
    /// Gmail was opened and the report still has to be attached there by
    /// hand (#5). Shown in the window until the sender says it's done.
    var awaitingGmailAttachment = false
    /// What the page provided when the screen opened (#208); nil while the
    /// page is still being asked.
    var pageDiagnostics: PageDiagnostics.Outcome?

    // What the app provides.
    @ObservationIgnored var gatherFacts: () -> ProblemReport.Facts = {
        ProblemReport.Facts(
            appVersion: "?", install: "?", psyNeuLinkSource: "?", developerMode: false,
            server: "?", steps: [], macOSVersion: "?", macModel: "?")
    }
    /// This launch's whole log (#208).
    @ObservationIgnored var gatherLogs: () -> [String] = { [] }
    /// The previous launch's log, when this launch is short enough for it
    /// to matter (`ProblemReport.attachPreviousLaunch`, #208); nil otherwise.
    @ObservationIgnored var gatherPreviousLogs: () -> [String]? = { nil }
    /// Every app setting (#208).
    @ObservationIgnored var gatherSettings: () -> SettingsSnapshot.Values? = { nil }
    /// Ask the page for its diagnostics (#208); answers once, within
    /// `PageDiagnostics.timeout`.
    @ObservationIgnored var gatherPageDiagnostics: (@escaping @MainActor (PageDiagnostics.Outcome) -> Void) -> Void = {
        $0(PageDiagnostics.noPage())
    }
    /// Snapshot of the app window, or nil when none is open.
    @ObservationIgnored var captureAppWindow: (@escaping @MainActor (NSImage?) -> Void) -> Void = { $0(nil) }
    @ObservationIgnored var sendWith: () -> String = { "ask" }
    /// The "Send to" setting; empty means `ReportDefaults.contactEmail`.
    @ObservationIgnored var sendTo: () -> String = { "" }
    @ObservationIgnored var developerMode: () -> Bool = { false }
    /// Downloads; a temporary folder in tests.
    @ObservationIgnored var destination: () -> URL = { ReportWriter.downloads }
    @ObservationIgnored var revealInFinder = true

    // MARK: Opening

    /// Open the screen. A report already saved starts a fresh one; a draft
    /// in progress is kept.
    func open() {
        if saved != nil { reset() }
        isOpen = true
        if shots.isEmpty && screenshotNote == nil { takeScreenshot() }
        if pageDiagnostics == nil { askThePage() }
    }

    func close() {
        isOpen = false
    }

    func reset() {
        whatHappened = ""
        expected = ""
        included = Set(ProblemReport.Part.allCases)
        shots = []
        screenshotNote = nil
        saved = nil
        savedRequest = nil
        error = nil
        copiedSummary = false
        awaitingGmailAttachment = false
        pageDiagnostics = nil
    }

    // MARK: The page's diagnostics (#208)

    /// Ask once per report. Whatever comes back, or doesn't, the report
    /// goes on; the included list shows the two page parts only when the
    /// page answered.
    func askThePage() {
        let asking = UUID()
        pageAsk = asking
        gatherPageDiagnostics { [weak self] outcome in
            guard let self, self.pageAsk == asking else { return }
            self.pageDiagnostics = outcome
        }
    }

    @ObservationIgnored private var pageAsk: UUID?

    /// The parts this report offers: `ProblemReport.offered`, over what's
    /// gathered now.
    var offeredParts: [ProblemReport.Part] {
        ProblemReport.offered(request())
    }

    // MARK: Screenshots

    /// The app window, taken by the app: `WKWebView.takeSnapshot`, which
    /// needs no screen-recording permission.
    func takeScreenshot() {
        captureAppWindow { [weak self] image in
            guard let self else { return }
            guard let image, let png = Self.png(from: image) else {
                self.screenshotNote = "No PsyNeuView window was open, so no screenshot was taken. "
                    + "Use Add another screenshot… to attach one."
                return
            }
            self.screenshotNote = nil
            self.shots.insert(Shot(image: image, png: png, source: "The app window"), at: 0)
        }
    }

    /// Image files the user picks, saved as PNGs.
    func addScreenshots() {
        let panel = NSOpenPanel()
        panel.title = "Add a Screenshot"
        panel.message = "Choose images to add to the report."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let image = NSImage(contentsOf: url), let png = Self.png(from: image) else {
                error = "Couldn't read \(url.lastPathComponent) as an image."
                continue
            }
            shots.append(Shot(image: image, png: png, source: url.lastPathComponent))
        }
    }

    static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: The report

    /// The screenshots to save, named in order.
    private var namedShots: [ReportWriter.Screenshot] {
        shots.filter(\.included).enumerated().map {
            ReportWriter.Screenshot(name: "screenshot-\($0.offset + 1).png", png: $0.element.png)
        }
    }

    func request(at date: Date = Date()) -> ProblemReport.Request {
        ProblemReport.Request(
            whatHappened: whatHappened,
            expected: expected,
            facts: gatherFacts(),
            logLines: gatherLogs(),
            previousLogLines: gatherPreviousLogs(),
            settings: gatherSettings(),
            page: pageDiagnostics ?? PageDiagnostics.timedOut(),
            included: included,
            screenshots: namedShots.map(\.name),
            screenshotNote: shots.contains(where: \.included) ? nil
                : (screenshotNote ?? "The sender left the screenshot out."),
            reference: ProblemReport.reference(for: date),
            date: date)
    }

    func preview(_ part: ProblemReport.Part) -> String {
        ProblemReport.preview(part, of: request())
    }

    func save() {
        error = nil
        let r = request()
        do {
            let s = try ReportWriter.save(
                reference: r.reference, files: ProblemReport.build(r),
                screenshots: namedShots, into: destination())
            var final = r
            // The folder may have been renamed to avoid a clash.
            final.reference = s.folder.lastPathComponent
            savedRequest = final
            saved = s
            if revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([s.folder])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Sending

    static let outlookBundleID = "com.microsoft.Outlook"

    var mailSetup: ProblemReport.MailSetup {
        let workspace = NSWorkspace.shared
        let handler = URL(string: "mailto:someone@example.com").flatMap { workspace.urlForApplication(toOpen: $0) }
        return ProblemReport.MailSetup(
            defaultMailApp: handler.flatMap { Bundle(url: $0)?.bundleIdentifier ?? $0.lastPathComponent },
            outlookInstalled: workspace.urlForApplication(withBundleIdentifier: Self.outlookBundleID) != nil)
    }

    var sendPlan: ProblemReport.SendPlan {
        ProblemReport.sendPlan(ProblemReport.SendWith(setting: sendWith()), setup: mailSetup)
    }

    var instructions: String {
        ProblemReport.sendInstructions(reference: savedRequest?.reference ?? "", sendTo: sendTo())
    }

    /// What to attach: the .zip when there is one (one file travels better),
    /// else the folder.
    private var attachment: URL? { saved?.zip ?? saved?.folder }

    func copySummary() {
        guard let r = savedRequest else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProblemReport.summary(r), forType: .string)
        copiedSummary = true
    }

    /// The macOS share sheet: Mail, Messages, AirDrop, and Slack or Teams if
    /// installed, with the report attached.
    func share(from view: NSView) {
        guard let attachment else { return }
        let picker = NSSharingServicePicker(items: [attachment])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// The default mail app (Mail, or Outlook if that's the default), with the
    /// report attached and addressed when "Send to" is set.
    func email() {
        guard let r = savedRequest, let attachment else { return }
        guard let service = NSSharingService(named: .composeEmail),
              service.canPerform(withItems: [attachment]) else {
            error = "No mail app is set up on this Mac. Use Share… or attach the folder yourself."
            return
        }
        service.recipients = [ProblemReport.contact(sendTo())]
        service.subject = ProblemReport.emailSubject(r)
        service.perform(withItems: [ProblemReport.summary(r), attachment])
    }

    /// Gmail's web compose. A link can't attach files (#5), so the report's
    /// .zip is also selected in Finder, ready to drag into Gmail, and the
    /// window asks for it until the sender confirms.
    func gmail() {
        guard let r = savedRequest, let url = ProblemReport.gmailURL(r, to: ProblemReport.contact(sendTo())) else { return }
        NSWorkspace.shared.open(url)
        revealAttachment()
        awaitingGmailAttachment = true
    }

    /// The file to drag into Gmail: the .zip, else the folder.
    var attachmentName: String { attachment?.lastPathComponent ?? "" }

    func revealAttachment() {
        guard let attachment else { return }
        NSWorkspace.shared.activateFileViewerSelecting([attachment])
    }

    func confirmGmailAttached() {
        awaitingGmailAttachment = false
    }

    /// Developer mode only: a prefilled new issue. The repos are private, so
    /// it's hidden for everyone else.
    func openIssue(in repo: ProblemReport.IssueRepo) {
        guard let r = savedRequest, let url = ProblemReport.issueURL(r, repo: repo) else { return }
        NSWorkspace.shared.open(url)
    }

    func showInFinder() {
        guard let folder = saved?.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
