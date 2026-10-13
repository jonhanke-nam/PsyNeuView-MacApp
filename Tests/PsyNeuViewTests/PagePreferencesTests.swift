import Foundation
import JavaScriptCore
import XCTest
@testable import PsyNeuView

/// Page preferences kept across launches (#218): the `pnvPrefs` messages,
/// the store's rules, and the user script — run for real in JavaScriptCore
/// over a stand-in `localStorage`, no web view.
final class PagePreferencesTests: XCTestCase {

    // MARK: Which keys

    func testOnlyPsyNeuViewPrefixesAreKept() {
        XCTAssertTrue(PagePreferences.isKept("psyneuview.openMenu.sectionOrder"))
        XCTAssertTrue(PagePreferences.isKept("psyneuview.shortcutOverrides.v1"))
        XCTAssertTrue(PagePreferences.isKept("psynewview_ui_prefs"))
        XCTAssertTrue(PagePreferences.isKept("psynewview_layout_outer_sizes"))
        XCTAssertTrue(PagePreferences.isKept("psynewview-gsc-legend"))
        XCTAssertFalse(PagePreferences.isKept("psyneuview"))
        XCTAssertFalse(PagePreferences.isKept("psyneuview_x"), "the new spelling uses a dot")
        XCTAssertFalse(PagePreferences.isKept("psynewview.x"), "the old spelling uses _ or -")
        XCTAssertFalse(PagePreferences.isKept("PsyNeuView.x"), "case matters, as it does in localStorage")
        XCTAssertFalse(PagePreferences.isKept("token"))
        XCTAssertFalse(PagePreferences.isKept(""))
        XCTAssertFalse(PagePreferences.isKept(" psyneuview.x"))
    }

    // MARK: Messages

    private func failure(_ r: Result<PagePreferences.Change, PagePreferences.Failure>) -> String? {
        if case .failure(let f) = r { return f.message }
        return nil
    }

    func testValidMessagesParse() {
        XCTAssertEqual(
            try PagePreferences.parse(["op": "set", "key": "psyneuview.a", "value": "1"]).get(),
            .set(key: "psyneuview.a", value: "1"))
        XCTAssertEqual(
            try PagePreferences.parse(["op": "set", "key": "psynewview_ui_prefs", "value": ""]).get(),
            .set(key: "psynewview_ui_prefs", value: ""), "an empty string is a value")
        XCTAssertEqual(
            try PagePreferences.parse(["op": "remove", "key": "psynewview-gsc-legend"]).get(),
            .remove(key: "psynewview-gsc-legend"))
        XCTAssertEqual(try PagePreferences.parse(["op": "clear"]).get(), .clear)
        XCTAssertEqual(
            try PagePreferences.parse(["op": "clear", "key": "ignored", "extra": 1]).get(), .clear,
            "extra fields are ignored")
    }

    func testBadShapesAreRefused() {
        XCTAssertEqual(failure(PagePreferences.parse("set")),
                       "pnvPrefs: message must be an object with an 'op' field")
        XCTAssertEqual(failure(PagePreferences.parse(["key": "psyneuview.a"])),
                       "pnvPrefs: message must be an object with an 'op' field")
        XCTAssertEqual(failure(PagePreferences.parse(["op": 1])),
                       "pnvPrefs: message must be an object with an 'op' field")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "get"])), "pnvPrefs: unknown op 'get'")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "set", "value": "1"])),
                       "pnvPrefs: 'set' needs a string 'key'")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "set", "key": 7, "value": "1"])),
                       "pnvPrefs: 'set' needs a string 'key'")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "set", "key": "psyneuview.a"])),
                       "pnvPrefs: 'set' needs a string 'value'")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "set", "key": "psyneuview.a", "value": 1])),
                       "pnvPrefs: 'set' needs a string 'value'")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "set", "key": "psyneuview.a", "value": NSNull()])),
                       "pnvPrefs: 'set' needs a string 'value'")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "remove"])),
                       "pnvPrefs: 'remove' needs a string 'key'")
    }

    func testOtherKeysAreRefused() {
        XCTAssertEqual(failure(PagePreferences.parse(["op": "set", "key": "token", "value": "x"])),
                       "pnvPrefs: 'token' is not a PsyNeuView preference key")
        XCTAssertEqual(failure(PagePreferences.parse(["op": "remove", "key": "theme"])),
                       "pnvPrefs: 'theme' is not a PsyNeuView preference key")
    }

    func testValueOverTheCapIsRefused() {
        let atCap = String(repeating: "x", count: PagePreferences.maxValueBytes)
        XCTAssertNotNil(try? PagePreferences.parse(["op": "set", "key": "psyneuview.a", "value": atCap]).get())
        let over = atCap + "x"
        XCTAssertEqual(
            failure(PagePreferences.parse(["op": "set", "key": "psyneuview.a", "value": over])),
            "pnvPrefs: 'psyneuview.a' is \(PagePreferences.maxValueBytes + 1) bytes; "
                + "values over \(PagePreferences.maxValueBytes) bytes aren't kept")
        // Bytes, not characters: a 3-byte character counts for three.
        let overInBytes = String(repeating: "é", count: PagePreferences.maxValueBytes / 2 + 1)
        XCTAssertNotNil(failure(PagePreferences.parse(["op": "set", "key": "psyneuview.a", "value": overInBytes])))
    }

    // MARK: Store rules

    func testSetRemoveAndClear() {
        var entries: [String: String] = [:]
        entries = PagePreferences.applying(.set(key: "psyneuview.a", value: "1"), to: entries).entries
        entries = PagePreferences.applying(.set(key: "psynewview_b", value: "2"), to: entries).entries
        XCTAssertEqual(entries, ["psyneuview.a": "1", "psynewview_b": "2"])
        entries = PagePreferences.applying(.set(key: "psyneuview.a", value: "3"), to: entries).entries
        XCTAssertEqual(entries["psyneuview.a"], "3", "last write wins")
        entries = PagePreferences.applying(.remove(key: "psyneuview.a"), to: entries).entries
        XCTAssertEqual(entries, ["psynewview_b": "2"])
        entries = PagePreferences.applying(.remove(key: "psyneuview.missing"), to: entries).entries
        XCTAssertEqual(entries, ["psynewview_b": "2"], "removing what isn't there changes nothing")
        XCTAssertEqual(PagePreferences.applying(.clear, to: entries), .init(entries: [:]))
    }

    func testClearForgetsOnlyKeptKeys() {
        // Can't get in through the bridge, but a plist could hold one.
        let entries = ["psyneuview.a": "1", "stray": "x"]
        XCTAssertEqual(PagePreferences.applying(.clear, to: entries).entries, ["stray": "x"])
    }

    func testSetOverTheTotalCapDropsTheKeyAndSaysSo() {
        let big = String(repeating: "x", count: PagePreferences.maxValueBytes)
        var entries: [String: String] = [:]
        // Three 64 KB values fit under 256 KB; the fourth does not.
        for i in 1...3 {
            let out = PagePreferences.applying(.set(key: "psyneuview.v\(i)", value: big), to: entries)
            XCTAssertNil(out.refused)
            entries = out.entries
        }
        let before = entries
        let out = PagePreferences.applying(.set(key: "psyneuview.v4", value: big), to: entries)
        XCTAssertEqual(out.entries, before)
        XCTAssertNotNil(out.refused)
        XCTAssertTrue(out.refused!.contains("psyneuview.v4"), out.refused!)
        XCTAssertTrue(out.refused!.contains("\(PagePreferences.maxTotalBytes)"), out.refused!)

        // Growing a key that was there drops it: its old value is stale.
        entries = PagePreferences.applying(.set(key: "psyneuview.v4", value: "small"), to: entries).entries
        XCTAssertEqual(entries["psyneuview.v4"], "small")
        let grow = PagePreferences.applying(.set(key: "psyneuview.v4", value: big), to: entries)
        XCTAssertNotNil(grow.refused)
        XCTAssertNil(grow.entries["psyneuview.v4"])
        XCTAssertEqual(grow.entries.count, 3)
    }

    func testTotalBytesCountsKeysAndValuesInUTF8() {
        XCTAssertEqual(PagePreferences.totalBytes([:]), 0)
        XCTAssertEqual(PagePreferences.totalBytes(["ab": "cd", "é": "ü"]), 4 + 4)
    }

    func testSanitizingWhatWasReadBack() {
        let big = String(repeating: "x", count: PagePreferences.maxValueBytes + 1)
        let raw = [
            "psyneuview.a": "1",
            "stray": "x",
            "psyneuview.big": big,
        ]
        XCTAssertEqual(PagePreferences.sanitized(raw), ["psyneuview.a": "1"])

        let fits = String(repeating: "y", count: PagePreferences.maxValueBytes)
        var tooMany: [String: String] = [:]
        for i in 1...6 { tooMany["psyneuview.v\(i)"] = fits }
        let trimmed = PagePreferences.sanitized(tooMany)
        XCTAssertLessThanOrEqual(PagePreferences.totalBytes(trimmed), PagePreferences.maxTotalBytes)
        XCTAssertEqual(trimmed.count, 3)
    }

    // MARK: The script's text

    func testScriptEmbedsTheEntriesAsSafeJSON() throws {
        let entries = [
            "psyneuview.quotes": "say \"hi\" and 'bye'",
            "psyneuview.backslash": "C:\\path\\to",
            "psyneuview.script": "</script><script>alert(1)</script>",
            "psyneuview.unicode": "héllo — 日本語 🎉",
            "psyneuview.lines": "one\ntwo\r\nthree\ttab",
            "psyneuview.separators": "a\u{2028}b\u{2029}c",
        ]
        let script = PagePreferences.userScript(seeding: entries)
        XCTAssertFalse(script.contains("</script>"), "a closing tag must never appear literally")
        XCTAssertTrue(script.contains(#"<\/script>"#))
        XCTAssertTrue(script.contains(#"say \"hi\" and 'bye'"#))
        XCTAssertTrue(script.contains(#"C:\\path\\to"#))
        XCTAssertTrue(script.contains(#"one\ntwo\r\nthree\ttab"#))
        XCTAssertTrue(script.contains("héllo — 日本語 🎉"))
        XCTAssertFalse(script.contains("\u{2028}"))
        XCTAssertFalse(script.contains("\u{2029}"))
        XCTAssertTrue(script.contains(#"a\u2028b\u2029c"#))
        XCTAssertTrue(script.contains("messageHandlers.pnvPrefs"))
        for prefix in PagePreferences.prefixes {
            XCTAssertTrue(script.contains("\"\(prefix)\""))
        }

        // The literal decodes back to exactly what went in.
        let literal = PagePreferences.jsObjectLiteral(entries)
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: String]
        XCTAssertEqual(decoded, entries)
    }

    func testEmptyStoreMakesAnEmptySeed() {
        XCTAssertTrue(PagePreferences.userScript(seeding: [:]).contains("var SEED = {};"))
    }

    // MARK: The script, run

    /// A page's worth of globals: a `Storage` with the real methods on its
    /// prototype, `window.localStorage`, and a `pnvPrefs` handler that
    /// records what it is posted.
    private func page(localStorage: [String: String] = [:]) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var exceptions: [String] = []
        context.exceptionHandler = { _, value in exceptions.append(value?.toString() ?? "?") }
        context.evaluateScript("""
            function Storage() { this._d = {}; }
            Storage.prototype.getItem = function (k) {
              return Object.prototype.hasOwnProperty.call(this._d, String(k)) ? this._d[String(k)] : null;
            };
            Storage.prototype.setItem = function (k, v) { this._d[String(k)] = String(v); };
            Storage.prototype.removeItem = function (k) { delete this._d[String(k)]; };
            Storage.prototype.clear = function () { this._d = {}; };
            Storage.prototype.key = function (i) { var ks = Object.keys(this._d); return i < ks.length ? ks[i] : null; };
            Object.defineProperty(Storage.prototype, 'length', { get: function () { return Object.keys(this._d).length; } });
            var window = this;
            window.localStorage = new Storage();
            window.sessionStorage = new Storage();
            var posted = [];
            window.webkit = { messageHandlers: { pnvPrefs: { postMessage: function (m) { posted.push(m); } } } };
            """)
        for (key, value) in localStorage {
            context.objectForKeyedSubscript("localStorage")
                .invokeMethod("setItem", withArguments: [key, value])
        }
        XCTAssertEqual(exceptions, [])
        return context
    }

    /// Read back through JSON, so no JS-to-Swift bridging is in the way.
    private func json<T>(_ expression: String, in context: JSContext, as type: T.Type) -> T? {
        guard let text = context.evaluateScript("JSON.stringify(\(expression))")?.toString() else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? T
    }

    private func storage(_ context: JSContext) -> [String: String] {
        json("window.localStorage._d", in: context, as: [String: String].self) ?? [:]
    }

    private func posted(_ context: JSContext) -> [[String: String]] {
        json("posted", in: context, as: [[String: String]].self) ?? []
    }

    private func run(_ script: String, in context: JSContext) {
        var exceptions: [String] = []
        context.exceptionHandler = { _, value in exceptions.append(value?.toString() ?? "?") }
        context.evaluateScript(script)
        XCTAssertEqual(exceptions, [], "the user script threw")
    }

    func testSeedFillsOnlyMissingKeysAndReportsThePagesOwn() throws {
        let context = try page(localStorage: [
            "psyneuview.theirs": "page", "psyneuview.same": "v", "other": "untouched",
        ])
        run(PagePreferences.userScript(seeding: [
            "psyneuview.theirs": "app", "psyneuview.same": "v", "psyneuview.new": "seeded",
        ]), in: context)
        XCTAssertEqual(storage(context), [
            "psyneuview.theirs": "page",
            "psyneuview.same": "v",
            "psyneuview.new": "seeded",
            "other": "untouched",
        ])
        // The page's value for 'theirs' is reported back; what matches isn't.
        XCTAssertEqual(posted(context), [["op": "set", "key": "psyneuview.theirs", "value": "page"]])
    }

    func testSeedValuesSurviveTheTripThroughTheScript() throws {
        let entries = [
            "psyneuview.quotes": "say \"hi\" and 'bye' \\ </script>",
            "psyneuview.unicode": "héllo — 日本語 🎉\u{2028}\n",
        ]
        let context = try page()
        run(PagePreferences.userScript(seeding: entries), in: context)
        XCTAssertEqual(storage(context), entries)
    }

    func testChangesToKeptKeysArePosted() throws {
        let context = try page()
        run(PagePreferences.userScript(seeding: [:]), in: context)
        context.evaluateScript("""
            window.localStorage.setItem('psyneuview.a', '1');
            window.localStorage.setItem('psynewview_b', 2);
            window.localStorage.setItem('other', 'x');
            window.sessionStorage.setItem('psyneuview.session', 'no');
            window.localStorage.removeItem('psyneuview.a');
            window.localStorage.removeItem('other');
            window.localStorage.clear();
            """)
        XCTAssertEqual(posted(context), [
            ["op": "set", "key": "psyneuview.a", "value": "1"],
            ["op": "set", "key": "psynewview_b", "value": "2"],
            ["op": "remove", "key": "psyneuview.a"],
            ["op": "clear"],
        ])
        XCTAssertEqual(storage(context), [:], "the originals still ran")
    }

    func testPageWithoutTheHandlerStillSeedsAndIsLeftAlone() throws {
        let context = try page(localStorage: ["psyneuview.x": "1"])
        context.evaluateScript("window.webkit = undefined;")
        run(PagePreferences.userScript(seeding: ["psyneuview.y": "2"]), in: context)
        XCTAssertEqual(storage(context), ["psyneuview.x": "1", "psyneuview.y": "2"])
        context.evaluateScript("window.localStorage.setItem('psyneuview.z', '3');")
        XCTAssertEqual(storage(context)["psyneuview.z"], "3")
        XCTAssertTrue(
            context.evaluateScript("Storage.prototype.setItem.toString()").toString()
                .contains("this._d[String(k)] = String(v)"),
            "no handler, nothing to wrap")
    }

    func testPageWithoutStorageIsLeftAlone() throws {
        let context = try page()
        context.evaluateScript("""
            Object.defineProperty(window, 'localStorage', { get: function () { throw new Error('SecurityError'); } });
            """)
        run(PagePreferences.userScript(seeding: ["psyneuview.y": "2"]), in: context)
        XCTAssertEqual(posted(context), [])
    }

    // MARK: The store

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "PagePreferencesTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    func testStoreKeepsEntriesInDefaults() {
        let store = PagePreferencesStore(defaults: defaults)
        XCTAssertEqual(store.count, 0)
        store.receive(["op": "set", "key": "psyneuview.a", "value": "1"])
        store.receive(["op": "set", "key": "psynewview_b", "value": "2"])
        store.receive(["op": "set", "key": "psyneuview.a", "value": "3"])
        XCTAssertEqual(store.entries, ["psyneuview.a": "3", "psynewview_b": "2"])
        XCTAssertEqual(store.keys, ["psyneuview.a", "psynewview_b"])

        let again = PagePreferencesStore(defaults: defaults)
        XCTAssertEqual(again.entries, store.entries, "read back on the next launch")

        again.receive(["op": "remove", "key": "psyneuview.a"])
        XCTAssertEqual(PagePreferencesStore(defaults: defaults).entries, ["psynewview_b": "2"])
        again.receive(["op": "clear"])
        XCTAssertEqual(PagePreferencesStore(defaults: defaults).entries, [:])
    }

    @MainActor
    func testStoreIgnoresBadMessagesAndLogsThem() {
        let store = PagePreferencesStore(defaults: defaults)
        var logged: [String] = []
        store.log = { logged.append($0) }
        store.receive(["op": "set", "key": "token", "value": "secret"])
        store.receive("junk")
        XCTAssertEqual(store.entries, [:])
        XCTAssertEqual(logged.count, 2)
        XCTAssertNil(defaults.dictionary(forKey: PagePreferences.defaultsKey))
    }

    @MainActor
    func testStoreLogsADroppedValueOncePerKey() {
        let store = PagePreferencesStore(defaults: defaults)
        var logged: [String] = []
        store.log = { logged.append($0) }
        let big = String(repeating: "x", count: PagePreferences.maxValueBytes)
        for i in 1...3 { store.apply(.set(key: "psyneuview.v\(i)", value: big)) }
        store.apply(.set(key: "psyneuview.v4", value: big))
        store.apply(.set(key: "psyneuview.v4", value: big))
        XCTAssertEqual(logged.count, 1, "a page that keeps writing one value doesn't fill the log")
        XCTAssertEqual(store.count, 3)
        // Once it fits, it is kept — and a later overflow is reported again.
        store.apply(.set(key: "psyneuview.v4", value: "small"))
        XCTAssertEqual(store.entries["psyneuview.v4"], "small")
        store.apply(.set(key: "psyneuview.v4", value: big))
        XCTAssertEqual(logged.count, 2)
    }

    @MainActor
    func testStoreSanitizesWhatItReadsBack() {
        defaults.set(["psyneuview.a": "1", "stray": "x"], forKey: PagePreferences.defaultsKey)
        XCTAssertEqual(PagePreferencesStore(defaults: defaults).entries, ["psyneuview.a": "1"])
        defaults.set("not a dictionary", forKey: PagePreferences.defaultsKey)
        XCTAssertEqual(PagePreferencesStore(defaults: defaults).entries, [:])
    }

    // MARK: Report a Problem

    func testReportNamesTheKeptKeysButNotTheirValues() throws {
        var facts = ProblemReportTests.facts
        facts.pagePreferenceKeys = ["psyneuview.openMenu.sectionOrder", "psynewview_ui_prefs"]
        let request = ProblemReport.Request(
            whatHappened: "x", expected: "", facts: facts, logLines: [],
            reference: "PNV-debugging-2026-10-06_14-03-22", date: ProblemReportTests.date)
        let files = ProblemReport.build(request, home: "/Users/someone", timeZone: ProblemReportTests.utc)
        XCTAssertTrue(files.markdown.contains(
            "- Page preferences kept by the app: 2 (psyneuview.openMenu.sectionOrder, psynewview_ui_prefs)"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: files.diagnostics) as? [String: Any])
        let versions = try XCTUnwrap(json["versions"] as? [String: Any])
        let prefs = try XCTUnwrap(versions["pagePreferences"] as? [String: Any])
        XCTAssertEqual(prefs["count"] as? Int, 2)
        XCTAssertEqual(prefs["keys"] as? [String], facts.pagePreferenceKeys)

        XCTAssertEqual(ProblemReport.pagePreferencesLine([]), "Page preferences kept by the app: none")
    }
}
