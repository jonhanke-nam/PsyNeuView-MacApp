# PsyNeuView-MacApp — Roadmap

## Current: v0.4.0 (April 2026)

**Status:** Working end-to-end. Configurable PsyNeuLink source. Branch switching for both PsyNeuView and PsyNeuLink.

What's done:
- Native Mac app with embedded WKWebView
- Zero-friction installer (auto-installs Homebrew, Python, Node, gh CLI)
- Single-process architecture (backend serves everything, no Node at runtime)
- Dynamic ports (no conflicts with other instances)
- GitHub OAuth login (no SSH keys needed)
- DMG distribution with `make github-release`
- PsyNeuLink brain logo as app icon
- Branch switching for PsyNeuView (Development menu) — main, devel, feature branches
  (clone path only since #74; the ⌘B shortcut is gone — see #75)
- Configurable PsyNeuLink source — PyPI or any branch from the Princeton GitHub repo
- PsyNeuView repo renamed: `main` = stable, `devel` = development

## Next: v0.5.0 — Production Ready (target: May 2026)

**Goal:** Confident enough to share with any collaborator.

- [ ] **Test full install flow end-to-end** on a clean Mac / new user account
- [x] ~~**Test `gh auth login`** through the setup wizard~~ — obsolete: #63 replaced
  the `gh` CLI with a native GitHub App device flow, verified end to end.
- [ ] **Test WebSocket** file watching in WKWebView
- [x] ~~**Developer ID signing + notarization**~~ — Done. Shipped releases verify as
  `Notarized Developer ID`; `make signed-dmg` and the tag-triggered release workflow
  sign, notarize and staple.
- [x] ~~**Upstream static serving patch** to PsyNeuView repo~~ — Done upstream;
  `backend/app/main.py` mounts the frontend itself. Removing the installer's now-dead
  patch is #69.
- [ ] **Fix demos retry** in PsyNeuView frontend (native retry, not injected JS)

## Future: Self-Updating App

**Goal:** The Mac app updates itself — users never download another DMG.

### Sparkle Framework Integration

[Sparkle](https://sparkle-project.org/) is the standard self-update framework for Mac apps.
Used by VS Code, Slack, Firefox, and thousands of other apps.

How it works:
1. On launch, Sparkle checks a URL (appcast XML) for new versions
2. If a new version is available, shows "Update Available" dialog
3. User clicks "Install Update" → downloads new DMG, replaces app, restarts
4. Fully automatic, no manual download needed

### Implementation steps

- [ ] Add Sparkle as a Swift Package dependency
- [ ] Create an appcast XML hosted on GitHub (or GitHub Pages)
- [ ] `make github-release` automatically updates the appcast
- [ ] Add Sparkle's `SUUpdater` to AppDelegate
- [ ] Configure update check interval (e.g., every 24 hours)
- [ ] Code signing required — Sparkle validates signatures to prevent tampering

### What this means for the update story

| What | How it updates |
|---|---|
| PsyNeuView code | Auto: `git pull` from tracked branch on launch |
| PsyNeuLink engine | Auto: upgrade from PyPI or GitHub branch on launch |
| Mac app itself | Auto: Sparkle checks for new DMG on launch |

Everything auto-updates. Users never manually download anything after first install.

### Prerequisites
- [ ] Apple Developer enrollment (needed for code signing)
- [ ] Code signing must be working first (Sparkle requires signed updates)

## Future: v1.0.0 — Mac App Store (target: June 2026)

**Goal:** Download from the App Store. Zero prerequisites. Just works.

### Architecture change: Bundled Python

Instead of installing Python/Homebrew at runtime, bundle everything inside the .app:

1. **Bundle Python runtime** — use `python-build-standalone` (~30MB standalone Python)
   embedded in `PsyNeuView.app/Contents/Frameworks/Python.framework/`
2. **Pre-install all pip packages** — PsyNeuLink, FastAPI, uvicorn, numpy, torch, etc.
   bundled in `PsyNeuView.app/Contents/Resources/site-packages/`
3. **Pre-build frontend** — `dist/` included in the app bundle
4. **Bundle backend code** — no git clone needed, backend code ships with the app
5. **Sandbox-compatible** — all executables inside the bundle, data in app container

### What changes

| Current (v0.2) | App Store (v1.0) |
|---|---|
| Install Python via Homebrew | Bundled in .app (~30MB) |
| `pip install` at runtime | Pre-installed in bundle |
| `git clone` from GitHub | Backend code ships in .app |
| `npm run build` at install | `dist/` ships in .app |
| GitHub access required | Not required |
| ~240KB DMG + 10min setup | ~500MB-1GB app, instant launch |
| Setup wizard | No setup needed |

### Build pipeline for App Store

```
make app-store
```

This would:
1. Download `python-build-standalone` for macOS arm64
2. Create a venv with the bundled Python
3. `pip install` all dependencies into it
4. `npm run build` the frontend
5. Assemble the .app bundle with everything inside
6. Code sign with Apple Distribution certificate
7. Create .pkg for App Store submission
8. Upload via `xcrun altool` or Transporter

### Considerations

- **App size:** ~500MB-1GB (PyTorch, numpy, scipy are large)
  - App Store limit is 4GB, so this is fine
  - Consider making PyTorch/TensorFlow optional to reduce size
- **Updates:** Each PsyNeuLink update requires a new App Store submission
  - Apple review takes 1-2 days
  - Consider a plugin/update system for PsyNeuLink models
- **Sandbox restrictions:**
  - User model files via NSOpenPanel (file picker) or app container
  - No access to arbitrary filesystem paths
  - Network access requires entitlement (straightforward)
- **Architecture:** Must build for both arm64 (Apple Silicon) and x86_64 (Intel)
  - Universal binary or separate submissions

### Prerequisites for App Store work

- [ ] Apple Developer Program enrollment ($99/year)
- [ ] Evaluate `python-build-standalone` for macOS — verify PsyNeuLink runs
- [ ] Test sandboxed execution of uvicorn from bundled Python
- [ ] Determine minimum viable dependency set (can we skip PyTorch for basic models?)
