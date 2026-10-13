# TODO — PsyNeuView-MacApp

> **Status lives on GitHub.** This file holds direction and pointers to
> issues. Release state is on the
> [releases page](https://github.com/jonhanke-nam/PsyNeuView-releases/releases);
> issue state is on the issue. An item with no issue number is real but not
> yet filed.

## Testing and verification

- Clean-Mac verification, including opening a published DMG on a second Mac
  (Gatekeeper is verified on the build machine; a clean second machine is the
  only literal test) — #45.
- Nothing tests the startup sequence or measures how long it takes — #104.
- Swift test target: run it in CI and cover core logic — #44.

## Install and setup

- Replace the `gh` CLI dependency with native GitHub device-flow OAuth (also
  covers the `gh auth login` flow no one has verified end to end) — #63.
- Bundle git (or move to libgit2) and drop the Xcode Command Line Tools
  requirement — #68.
- Stop writing to the user's checkout: delete `patchBackendForStaticServing`
  rather than upstreaming it — #69.

## Ideas

- **Retry demos on load.** The app injects a JS retry as a workaround; the
  PsyNeuView frontend should retry failed API calls itself. Not yet filed.
- **DMG background image** with an arrow showing drag-to-install. Not yet filed.
- **Crash reporting** — collect and report crashes for debugging. Not yet filed.

## Reference

- **Actions spending cap.** macOS runners bill at a 10× minute multiplier, so
  this repo reaches the cap before the others; it has blocked releases
  (2026-08-18, 2026-08-25). Symptom: jobs fail in seconds with "recent account
  payments have failed or your spending limit needs to be increased". Only the
  account owner can fix it. Local notarization is the fallback, but Apple's
  timestamp service throttles after roughly 15 signings in a day and clears
  after about an hour.
- How release notes are written: [docs/release-notes.md](docs/release-notes.md).
