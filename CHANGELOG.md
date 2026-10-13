# Changelog (retired)

**This file stopped being maintained after v0.4.9.** It is kept for the history
below, which is not recorded anywhere else.

Release notes now live with the releases themselves, written as the annotated
tag message when a version is cut:

- **Every version, one page:** https://github.com/jonhanke-nam/PsyNeuView-releases/blob/main/CHANGELOG.md
- **Downloads and per-version notes:** https://github.com/jonhanke-nam/PsyNeuView-releases/releases

That public changelog is generated from the published releases by
`scripts/generate-changelog.sh`, so there is one source and nothing to keep in
sync by hand. This file drifted twelve releases before anyone noticed, which is
the argument against maintaining a second copy (#161).

How release notes are written: [docs/release-notes.md](docs/release-notes.md).

---

## Historical entries (v0.4.9 and earlier)

## v0.4.9 — 2026-08-18

### Fixed
- **Restart Services now closes the old app window** instead of leaving it
  stranded next to the fresh one. The old window pointed at the previous backend
  (and possibly an old port); a new window reopens automatically once services
  are back up.

## v0.4.8 — 2026-08-18

### Changed
- **Default the PsyNeuLink source to Princeton GitHub `devel`** (was PyPI). PyPI
  trails the source PsyNeuView develops against and lacks newer library models
  (e.g. the Giallanza2024 EGO study), so the "PsyNeuLink Library" menu and
  features now match by default. Switchable in Preferences → PsyNeuLink Source
  (PyPI / master / devel / fork). (#47)

## v0.4.7 — 2026-08-18

### Added
- **Developer mode tools** in the Development menu (shown when Developer mode is
  on): open the running app URL, open the backend **API docs** (`/docs`), copy
  the backend URL, reveal the cloned repo in Finder, open it in your editor, and
  copy a diagnostics summary — so a developer can see what's happening on their
  machine. (#43)
- **Regression test suite** + CI: the Swift test target is re-enabled and
  `swift test` runs on every push/PR, covering branch-picker gating, PsyNeuLink
  source args, version comparison, port finding, and PATH resolution. (#44)

## v0.4.6 — 2026-08-18

First release with the **fully automated** pipeline *and* auto-update publishing:
tag push → CI builds, signs, notarizes, signs the update, and publishes the
Sparkle appcast — so existing installs self-update. (#22)

## v0.4.5 — 2026-08-18

First release cut entirely by CI on tag push (#22).

### Fixed
- **Swift concurrency errors that broke the CI build** — `SetupWizardView` is
  now `@MainActor` (its `@State Installer()` + `stepStatuses`/`onOutput` accesses
  are main-actor-isolated), the menubar timer re-captures `[weak self]` across
  its `Task`, and `Shell._userPath` is `nonisolated(unsafe)`. (#37)

### Added
- **build-check CI** — compiles (`swift build -c release`) on every push/PR on
  the release runner, so CI-only compile failures are caught before a release. (#37)

## v0.4.4 — 2026-08-18

### Added
- **Developer mode** (Preferences). The branch picker now shows only the tested
  branches (`devel`/`main`) by default; enabling Developer mode surfaces all
  branches, including unstable feature branches — so switching to unstable code
  is a deliberate opt-in, not an easy misclick. (#34)

## v0.4.3 — 2026-08-18

### Fixed
- **Track PsyNeuView `devel` by default, not `main`.** `main` is dormant (no
  devel->main promotion) and was ~3 months / 861 commits stale, so fresh
  installs shipped badly outdated code. The initial clone and the tracked-branch
  default now both use `devel` — the active, CI-tested trunk.

## v0.4.2 — 2026-08-18

First fully signed **and notarized** release — installs with no "unidentified
developer" Gatekeeper warning.

### Added
- **Notarize + staple the `.app` itself** (`scripts/notarize-app.sh`, run before
  the DMG is built) so the app carries its own ticket and offline first-launch
  is robust — in addition to the notarized+stapled DMG. (#31)

### Fixed
- **Notarization no longer silently skipped.** `release.sh` probed the wrong
  Keychain service name; it now checks the real profile via `notarytool
  history`. Combined with completed Developer Program enrollment + agreement,
  signing and notarization work end-to-end. (#18, PR #30)

## Unreleased

### Fixed
- **Setup wizard now detects unlinked Homebrew Python.** If `python@3.X` is
  installed via Homebrew but the `python3` symlink is missing from PATH (e.g.
  unlinked keg), the wizard now finds the keg, runs `brew link --overwrite` to
  expose `python3`, and proceeds — instead of treating Homebrew's "already
  installed and up-to-date" warning as a failed install. (#24)

## v0.4.1 — 2026-04-30

### Fixed
- **Installer/Updater install backend deps from `pyproject.toml`** instead of a
  hardcoded list. New backend dependencies (e.g. `python-multipart`) now flow
  automatically without an Installer code change. (#9, PR #11)
- **Native file picker for in-app file inputs** — `Toolbar → Import MDF...` and
  similar `<input type="file">` controls now surface an `NSOpenPanel`. Previously
  they were a silent no-op inside WKWebView. (#12, PR #13)

## v0.4.0 — 2026-04-28

### Added
- **PsyNeuLink source selection** — Install PsyNeuLink from PyPI (default) or any branch
  of the [Princeton GitHub repo](https://github.com/PrincetonUniversity/PsyNeuLink).
  Configurable in Preferences (Cmd+,).
- **Branch warnings** — Preferences UI shows warnings for experimental (non-tested) branches.
- **CHANGELOG.md** — This file, documenting version history.

### Changed
- **PsyNeuView repo branches renamed** — `stable` is now `main` (default); `main` is now `devel`.
  The app defaults to cloning and tracking the `main` branch.
- **Preferences window** expanded with a new "PsyNeuLink Source" section.
- Updated all documentation (README, INSTALL, ROADMAP, TODO) to reflect new branch names
  and PsyNeuLink source options.

## v0.3.1 — 2026-04-28

### Fixed
- Minor bug fixes and stability improvements.

## v0.3.0 — 2026-04-27

### Added
- **Branch switching** — Development menu > Switch Branch (Cmd+B) lets you switch
  between any remote branch of PsyNeuView. The app stops services, checks out the
  new branch, pulls, rebuilds, and restarts.
- **Auto-update on launch** — The app checks for updates on the tracked branch at
  startup, pulls new code, and rebuilds the frontend if needed.
- **PsyNeuLink auto-upgrade** — Checks PyPI for newer PsyNeuLink versions on each
  update cycle.
- **Preferences window** (Cmd+,) — Configure repo path, auto-restart, and launch at login.

### Changed
- Updater tracks a configurable branch (stored in Preferences) instead of always
  using `stable`.

## v0.2.0 — 2026-04-20

### Added
- **GitHub OAuth authentication** — Uses `gh auth login` with browser-based device flow.
  No SSH keys required. The setup wizard copies the one-time code to clipboard and
  opens the browser automatically.
- **Zero-friction installer** — Auto-installs Xcode CLI tools, Homebrew, Python 3.9+,
  Node.js 18+, and GitHub CLI if missing.
- **DMG distribution** — `make dmg` creates a distributable disk image with
  drag-to-install Applications shortcut.
- **GitHub Releases** — `make github-release` creates a tagged release with the DMG
  attached.
- **App icon** — PsyNeuLink brain logo as the application icon.

## v0.1.0 — 2026-04-13

### Added
- **Initial release** — Native macOS app wrapping PsyNeuView in a WKWebView window.
- **Process management** — Starts and stops backend (uvicorn) and frontend (Vite)
  processes automatically.
- **Dynamic ports** — Allocates free ports at startup so multiple instances can coexist.
- **Setup wizard** — Guides first-time users through cloning the repo and installing
  dependencies.
- **Menubar status item** — Brain icon in the menubar shows service status (green/yellow/red).
- **Log viewer** — Development > View Logs shows backend and frontend output in real time.
- **Health checking** — Polls backend and frontend health endpoints to detect crashes
  and trigger auto-restart.
- **Single-process architecture** — Backend serves the built frontend statically;
  no Node.js process needed at runtime.
