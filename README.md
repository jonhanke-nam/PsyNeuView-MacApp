# PsyNeuView-MacApp

A native macOS app for PsyNeuView — the visual editor for PsyNeuLink computational models. One app that handles installation, launching, and provides the full PsyNeuView interface embedded in a native window.

**[Download](https://jonhanke-nam.github.io/PsyNeuView-releases/)** | **[Install guide](INSTALL.md)**

## For Users

### Install from DMG

1. Download the DMG from the [download page](https://jonhanke-nam.github.io/PsyNeuView-releases/)
2. Drag **PsyNeuView** to **Applications**
3. Launch it and click **Get Started**

PsyNeuView and the Python it runs on ship inside the app, so setup installs
nothing on your machine and asks for nothing — no GitHub account, no Homebrew,
no Python, no Node. It does download the scientific packages PsyNeuLink needs,
which takes about ten minutes the first time.

See [INSTALL.md](INSTALL.md) for detail, including exactly where it puts things.

### Requirements

- macOS 14 (Sonoma) or later, on Apple silicon
- An internet connection for the first launch

### Day-to-day Use

- Launch PsyNeuView from Applications — it starts the backend and frontend automatically
- The PsyNeuView interface appears in a native Mac window
- **Cmd+N** opens additional windows
- **Development ▸ Switch Branch** switches PsyNeuView branches (`main`, `devel`,
  feature branches). Only available when PsyNeuView was cloned rather than
  bundled with the app — a bundled install has no checkout to switch.
- **Settings…** (Cmd+,) opens PsyNeuView's Settings in the app window — the
  same Settings as the gear icon. Its **Mac app** section has the settings
  only the app can act on: which PsyNeuView runs (the one included with the app
  or a checkout), auto-restart, launch at login, and how problem reports are
  sent.
- Use the **Development > View Logs** menu to troubleshoot issues
- **Help ▸ Report a Problem…** (also a button in Logs, and on the starting
  window when PsyNeuView doesn't start) saves a report folder,
  `PNV-debugging-<date>`, with a `.zip` beside it in Downloads: your
  description, the app window's screenshot, versions, where PsyNeuView runs
  from, the startup and update outcome, every app setting, this launch's
  whole log (`logs.txt`), and, when PsyNeuView provides them, its own state
  and activity since launch (`page-state.json`, `activity.txt`). A report made
  within two minutes of launch also carries the previous launch's log
  (`logs-previous-launch.txt`), for a start that failed. Tokens and passwords
  are removed, your "Send to" address is never quoted, and your home folder is
  shown as `~`; nothing outside PsyNeuView, PsyNeuLink and their installs is
  collected. Every part can be viewed or left out before saving; then send it
  with Share…, Email or Gmail.
- Each launch's log is also written to `~/Library/Logs/PsyNeuView/launch-<date>.log`
  as it happens (the last five launches, 5 MB each), so a report can carry
  the whole launch rather than what the Logs window kept.
- Close all windows to quit (services stop automatically)

### PsyNeuLink Source

By default, PsyNeuLink is installed from PyPI (the official release). You can switch to
installing from a specific branch of the [Princeton GitHub repo](https://github.com/PrincetonUniversity/PsyNeuLink),
or from a local checkout, in PsyNeuView's **Settings ▸ Environment ▸ Change install**
(Cmd+, or the gear icon), which installs it straight away:

| Source | Description |
|---|---|
| **PyPI** (default) | Official release from the Python Package Index |
| **GitHub — master** | Stable release branch from the Princeton repo |
| **GitHub — devel** | Development branch — passes all tests |
| **GitHub — other** | Experimental branches — may not pass all tests |
| **Local checkout** | A PsyNeuLink folder on your machine, installed editable, e.g. the one you develop in |

## For Developers

To work on PsyNeuView itself, choose **A PsyNeuView checkout** in
**Settings ▸ Mac app** and point it at your clone (its frontend built with
`npm run build`). Switching back to the version included with the app is the
same choice; nothing is deleted.

### Settings and native UI: the app is a thin wrapper

The Mac app is a thin wrapper around PsyNeuView's React app
([PsyNeuView-archive#1279](https://github.com/jonhanke-nam/PsyNeuView-archive/issues/1279),
#200). When you add UI:

1. **Any UI that can live in React lives in React,** so it works the same in a
   browser and in the app. Settings is the first case: Cmd+, and the gear icon
   open the same React Settings. The app has no settings UI of its own.
2. **The app contributes only what React can't do** — native file dialogs,
   starting and stopping the server, installs and updates, launch at login —
   through **bridges** (`pnvFile`, `pnvSettings`; see
   `Services/FileBridge.swift` and `Services/SettingsBridge.swift`, which
   document each one's JS contract) and **menu items that route into the React
   UI** (Settings… sends the page `pnv:open-settings`).
3. **React detects the bridge** and shows Mac-only parts, like the **Mac app**
   section of Settings, only when it is present. In a browser they are absent
   and nothing else differs.
   One bridge the page never sees: `pnvPrefs` (#218,
   `Services/PagePreferences.swift`). The page's own preferences live in its
   `localStorage`, which belongs to the page's origin — and the origin
   includes the port the backend happens to run on. The app reuses the last
   port when it is free, and, whatever the port, a user script in every app
   window seeds `localStorage` with the PsyNeuView keys the app kept
   (`psyneuview.*`, `psynewview_*`, `psynewview-*`, nothing else) and posts
   each later change back to the app to keep. The page needs no change and
   older PsyNeuView versions get it too.
4. **One control and one owner per setting.** A setting has exactly one home and
   one control; a second way to change it is a bug. The side that acts on a
   value owns it, and the other side asks rather than keeping its own copy.
   Every setting is listed in PsyNeuView's `docs/settings-inventory.yaml`; a
   new Mac-only setting goes there (`home: settings:mac-app`) and into
   `SettingsBridge.macAppKeys`.

**Native windows are exceptions** for what must work before React exists or
when it can't run: the Setup Wizard, the starting window (with its progress
checklist), Logs, and About. `NativeWindowPolicyTests` lists them with their
reasons and fails on any other native window — including a settings window —
until it is added there with an equally concrete reason, also written next to
the code that makes it.

### Build from Source

```bash
git clone git@github.com:jonhanke-nam/PsyNeuView-MacApp.git
cd PsyNeuView-MacApp

# Run directly from source
make run

# Build .app bundle
make app

# Build "PsyNeuView Test.app": the same build under a test identity, to run
# beside the real app without touching its settings or folders (#209).
# See docs/testing.md.
make test-app

# Install to /Applications
make install

# Build distributable DMG
make dmg

# Clean everything
make clean
```

### Testing

[docs/testing.md](docs/testing.md): the testing ladder, the test app
(`make test-app`), `scripts/pnv-status` to list every PsyNeuView running on
the Mac, the hand-test checklist per release, and the fresh-user test on a
second macOS account. The backend is told which app launched it in
`PSYNEUVIEW_APP_FLAVOR` (`release` or `test`), documented there.

### Open in Xcode

```bash
open Package.swift
```

## Architecture

PsyNeuView-MacApp is a Swift/SwiftUI app with zero external dependencies. It manages two processes:

- **Backend**: Python FastAPI server (uvicorn) running PsyNeuLink
- **Frontend**: Vite dev server serving the React UI

The React UI is embedded in a native `WKWebView` window — no browser required. Ports are dynamically allocated at startup so multiple instances can coexist.

```
Sources/PsyNeuView/
├── main.swift              # Entry point
├── AppDelegate.swift       # Windows, menus, lifecycle
├── Models/                 # AppState, Preferences, ServerStatus, LogEntry
├── Services/               # ProcessManager, HealthChecker, DependencyChecker,
│                           # Installer, PortChecker, LogCollector
├── Views/                  # AppWindowView (WKWebView + bridges), SetupWizard,
│                           # LogWindow, About, StatusMenu
└── Utilities/              # Shell wrapper, Constants
```

## Distribution

### Build targets

```bash
make dmg            # Unsigned DMG (for local testing)
make sign           # Code sign the .app with Developer ID
make signed-dmg     # Signed + notarized DMG (for distribution)
make github-release # Full pipeline: sign, DMG, notarize, appcast, GitHub Release
```

### How distribution works

Source code lives in this repo. Distribution happens through:

- **[PsyNeuView-releases](https://github.com/jonhanke-nam/PsyNeuView-releases)** — a public repo
  that hosts the download page, the **DMG release assets**, and the Sparkle
  auto-update feed (appcast) via GitHub Pages
- **GitHub Releases** (on this repo) — the signed+notarized DMG is also
  attached here for provenance, but the copy Sparkle downloads is the one in the
  releases repo, which keeps the feed's URLs stable. (When this repo was private,
  Sparkle's anonymous download of its assets 404'd — see #52.)

### Auto-updates (Sparkle)

The app uses [Sparkle](https://sparkle-project.org/) to check for updates on launch:

1. Sparkle fetches the [appcast.xml](https://jonhanke-nam.github.io/PsyNeuView-releases/appcast.xml)
   from the public releases repo
2. If a new version is available, it shows an "Update Available" dialog
3. The user clicks "Install Update" — Sparkle downloads the signed DMG, replaces the app, and restarts

The appcast is updated automatically by `scripts/update-appcast.sh` as part of `make github-release`.

> **First-check caveat:** immediately after a release, an existing install's very
> first check can fail to download if it's holding a briefly-stale cached appcast.
> It self-heals within ~10 minutes (feed cache revalidation) or on next launch —
> just re-run **Check for App Updates…**. See #52.

### Signing keys

- **Developer ID certificate** — in Keychain (imported from .p12), used for code signing
- **Sparkle EdDSA key** — in Keychain (generated by `generate_keys`), used to sign the appcast
- **Notarization credentials** — in Keychain (stored via `notarytool store-credentials`)
- No secrets are stored in the repo

See [CHANGELOG.md](CHANGELOG.md) for version history.

## License

PsyNeuView for Mac is licensed under the [Apache License, Version 2.0](LICENSE),
the same license as PsyNeuView and PsyNeuLink. See [NOTICE](NOTICE).
