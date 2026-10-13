import Foundation

/// Keeps the page's own preferences across launches (#218).
///
/// PsyNeuView remembers its per-browser preferences in `localStorage`: the
/// Open menu's section order, panel sizes and visibility, the palette,
/// recent paths, shortcut overrides, the graph pointer, the last Settings
/// section, walkthrough preferences. Storage belongs to the page's origin,
/// and the origin includes the port. The app starts the backend on a free
/// port, so until #218 every launch could land on a new origin, and the page
/// forgot all of it. A stable port (`PortChecker.choosePort`) keeps the
/// origin most of the time; this keeps the preferences whatever the port,
/// and it works with PsyNeuView versions that know nothing about it, because
/// the page is not involved: the app does it all with one user script.
///
/// How it works:
///
/// 1. **Store.** The entries live in the app's `UserDefaults` under
///    `defaultsKey`, as a `[String: String]`, and only for keys that start
///    with one of `prefixes` — PsyNeuView's own storage keys. Nothing else in
///    `localStorage` is kept. One value is capped at `maxValueBytes`, the
///    whole store at `maxTotalBytes`; a write that would go over is dropped
///    (with a log line) rather than kept half.
/// 2. **Seed.** A `WKUserScript` at document start, main frame only, writes
///    the stored entries into `localStorage` — only for keys that aren't
///    there yet, so when the origin *is* the same as last time the page's own
///    value wins. Any value already there under a kept key is then sent back
///    to the store, so the two agree.
/// 3. **Mirror.** The same script wraps `Storage.prototype.setItem`,
///    `removeItem` and `clear` so that, after the original has run, a change
///    to a kept key in `window.localStorage` is posted to the `pnvPrefs`
///    message handler (fire-and-forget; no reply):
///
///        { op: "set", key, value }   key and value are strings
///        { op: "remove", key }
///        { op: "clear" }             forgets every kept key
///
///    Only `localStorage` is mirrored (`sessionStorage` is per tab and meant
///    to go). Only the method calls are seen; PsyNeuView uses them, never
///    `localStorage.x = …`.
///
/// Every app window gets the script and the handler, and they share one
/// store, so the last write from any window wins — the same as two tabs on
/// one origin. Multiple windows on one origin already share `localStorage`.
///
/// Message checking, the store's rules and the script's text are pure
/// functions here, so they are tested without a web view. `PagePreferencesStore`
/// holds the entries and writes them to `UserDefaults`.
enum PagePreferences {
    static let handlerName = "pnvPrefs"

    /// PsyNeuView's storage-key prefixes: `psyneuview.` (newer keys, e.g.
    /// `psyneuview.openMenu.sectionOrder`), and the older spellings
    /// `psynewview_` / `psynewview-` (`psynewview_ui_prefs`,
    /// `psynewview_layout_outer_sizes`, `psynewview-gsc-legend`).
    static let prefixes = ["psyneuview.", "psynewview_", "psynewview-"]

    static let defaultsKey = "pagePreferences"

    /// One value: the largest PsyNeuView keeps is a few KB of JSON.
    static let maxValueBytes = 64 * 1024
    /// All of them, keys included.
    static let maxTotalBytes = 256 * 1024

    /// Whether a `localStorage` key is one the app keeps.
    static func isKept(_ key: String) -> Bool {
        prefixes.contains { key.hasPrefix($0) }
    }

    // MARK: Messages

    enum Change: Equatable {
        case set(key: String, value: String)
        case remove(key: String)
        case clear
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// What a `pnvPrefs` message asks for, or why it is ignored. Strict on
    /// purpose: the script is the app's own, so anything else is a bug or
    /// someone else's script, and neither gets into the store.
    static func parse(_ body: Any) -> Result<Change, Failure> {
        guard let body = body as? [String: Any], let op = body["op"] as? String else {
            return .failure(Failure(message: "pnvPrefs: message must be an object with an 'op' field"))
        }
        switch op {
        case "set":
            guard let key = body["key"] as? String else {
                return .failure(Failure(message: "pnvPrefs: 'set' needs a string 'key'"))
            }
            guard isKept(key) else {
                return .failure(Failure(message: "pnvPrefs: '\(key)' is not a PsyNeuView preference key"))
            }
            guard let value = body["value"] as? String else {
                return .failure(Failure(message: "pnvPrefs: 'set' needs a string 'value'"))
            }
            guard value.utf8.count <= maxValueBytes else {
                return .failure(Failure(
                    message: "pnvPrefs: '\(key)' is \(value.utf8.count) bytes; values over \(maxValueBytes) bytes aren't kept"))
            }
            return .success(.set(key: key, value: value))
        case "remove":
            guard let key = body["key"] as? String else {
                return .failure(Failure(message: "pnvPrefs: 'remove' needs a string 'key'"))
            }
            guard isKept(key) else {
                return .failure(Failure(message: "pnvPrefs: '\(key)' is not a PsyNeuView preference key"))
            }
            return .success(.remove(key: key))
        case "clear":
            return .success(.clear)
        default:
            return .failure(Failure(message: "pnvPrefs: unknown op '\(op)'"))
        }
    }

    // MARK: Store rules

    /// The entries after a change, and why a `set` was not kept when it
    /// wasn't. A `set` that would take the store over `maxTotalBytes` drops
    /// the key altogether: keeping the old value would seed a value the page
    /// has moved on from.
    struct Outcome: Equatable {
        var entries: [String: String]
        var refused: String? = nil
    }

    /// Bytes of UTF-8 across keys and values, what the total cap counts.
    static func totalBytes(_ entries: [String: String]) -> Int {
        entries.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }

    static func applying(_ change: Change, to entries: [String: String]) -> Outcome {
        var next = entries
        switch change {
        case .set(let key, let value):
            guard isKept(key), value.utf8.count <= maxValueBytes else {
                next.removeValue(forKey: key)
                return Outcome(entries: next, refused: "pnvPrefs: '\(key)' is not kept")
            }
            next[key] = value
            let total = totalBytes(next)
            if total > maxTotalBytes {
                next.removeValue(forKey: key)
                return Outcome(
                    entries: next,
                    refused: "Page preference '\(key)' not kept: all of them together would be "
                        + "\(total) bytes, over the \(maxTotalBytes)-byte limit.")
            }
            return Outcome(entries: next)
        case .remove(let key):
            next.removeValue(forKey: key)
            return Outcome(entries: next)
        case .clear:
            return Outcome(entries: next.filter { !isKept($0.key) })
        }
    }

    /// Only the kept keys of what was read back from `UserDefaults`, each
    /// within its cap, so a hand-edited or older plist can't smuggle anything
    /// in.
    static func sanitized(_ raw: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        for (key, value) in raw where isKept(key) && value.utf8.count <= maxValueBytes {
            clean[key] = value
        }
        while totalBytes(clean) > maxTotalBytes, let largest = clean.max(by: {
            $0.key.utf8.count + $0.value.utf8.count < $1.key.utf8.count + $1.value.utf8.count
        }) {
            clean.removeValue(forKey: largest.key)
        }
        return clean
    }

    // MARK: The user script

    /// The entries as a JS object literal. JSON is valid JS, and
    /// `JSONSerialization` escapes `/` (so `</script>` can't close anything,
    /// should the text ever land in HTML) and quotes, backslashes and
    /// control characters; U+2028/2029 are escaped here as well, for engines
    /// that still treat them as line terminators in string literals.
    static func jsObjectLiteral(_ entries: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// The script each app window runs at document start: seed, then mirror.
    /// Everything is inside try/catch — a page that can't use storage (or a
    /// handler that isn't there) must load exactly as before.
    static func userScript(seeding entries: [String: String]) -> String {
        let prefixData = (try? JSONSerialization.data(withJSONObject: PagePreferences.prefixes)) ?? Data("[]".utf8)
        let prefixes = String(decoding: prefixData, as: UTF8.self)
        return """
        (function () {
          'use strict';
          var PREFIXES = \(prefixes);
          var SEED = \(jsObjectLiteral(entries));
          function kept(key) {
            if (typeof key !== 'string') return false;
            for (var i = 0; i < PREFIXES.length; i++) {
              if (key.indexOf(PREFIXES[i]) === 0) return true;
            }
            return false;
          }
          var ls = null;
          try { ls = window.localStorage; } catch (e) { ls = null; }
          if (!ls) return;
          var handler = null;
          try {
            handler = window.webkit && window.webkit.messageHandlers
              && window.webkit.messageHandlers.\(handlerName);
          } catch (e) { handler = null; }
          function post(message) {
            if (!handler) return;
            try { handler.postMessage(message); } catch (e) {}
          }
          // Seed: what the app kept, for keys the page hasn't set on this origin.
          var key, value;
          for (key in SEED) {
            if (!Object.prototype.hasOwnProperty.call(SEED, key)) continue;
            try {
              if (ls.getItem(key) === null) ls.setItem(key, SEED[key]);
            } catch (e) {}
          }
          // The page's own values on this origin win; tell the app about them.
          try {
            for (var i = 0; i < ls.length; i++) {
              key = ls.key(i);
              if (!kept(key)) continue;
              value = ls.getItem(key);
              if (typeof value === 'string' && SEED[key] !== value) {
                post({ op: 'set', key: key, value: value });
              }
            }
          } catch (e) {}
          // Mirror: every change to a kept key in localStorage, after it happened.
          if (!handler || typeof Storage === 'undefined' || !Storage.prototype) return;
          try {
            var proto = Storage.prototype;
            var originalSetItem = proto.setItem;
            var originalRemoveItem = proto.removeItem;
            var originalClear = proto.clear;
            proto.setItem = function (k, v) {
              var result = originalSetItem.apply(this, arguments);
              try {
                if (this === ls && kept(String(k))) {
                  post({ op: 'set', key: String(k), value: String(v) });
                }
              } catch (e) {}
              return result;
            };
            proto.removeItem = function (k) {
              var result = originalRemoveItem.apply(this, arguments);
              try {
                if (this === ls && kept(String(k))) post({ op: 'remove', key: String(k) });
              } catch (e) {}
              return result;
            };
            proto.clear = function () {
              var result = originalClear.apply(this, arguments);
              try {
                if (this === ls) post({ op: 'clear' });
              } catch (e) {}
              return result;
            };
          } catch (e) {}
        })();
        """
    }
}

/// The app's one store of page preferences (#218): the entries, in memory
/// and in `UserDefaults`. Every app window's `pnvPrefs` handler writes here;
/// every new window is seeded from here. On the main actor, where the web
/// views and their message handlers are.
@MainActor
final class PagePreferencesStore {
    private let defaults: UserDefaults
    /// Where to say a value was dropped; the app passes its log.
    var log: (String) -> Void = { _ in }
    private(set) var entries: [String: String]
    /// Keys already reported as dropped, so a page that keeps writing one
    /// doesn't fill the log.
    private var reported: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: PagePreferences.defaultsKey) as? [String: String] ?? [:]
        self.entries = PagePreferences.sanitized(raw)
    }

    var count: Int { entries.count }

    /// The kept keys, sorted, for Report a Problem (names only; the values
    /// are the user's).
    var keys: [String] { entries.keys.sorted() }

    /// What the page sent; ignored with a log line when it isn't a valid
    /// change (which the app's own script never sends).
    func receive(_ body: Any) {
        switch PagePreferences.parse(body) {
        case .success(let change):
            apply(change)
        case .failure(let failure):
            report(failure.message, key: nil)
        }
    }

    func apply(_ change: PagePreferences.Change) {
        let outcome = PagePreferences.applying(change, to: entries)
        if outcome.entries != entries {
            entries = outcome.entries
            defaults.set(entries, forKey: PagePreferences.defaultsKey)
        }
        if let refused = outcome.refused {
            var key: String?
            if case .set(let k, _) = change { key = k }
            report(refused, key: key)
        } else if case .set(let k, _) = change {
            reported.remove(k)
        }
    }

    private func report(_ message: String, key: String?) {
        if let key {
            guard !reported.contains(key) else { return }
            reported.insert(key)
        }
        log(message)
    }
}
