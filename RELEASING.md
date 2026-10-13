# Releasing PsyNeuView-MacApp

Two paths exist:

- **Tag-push CI** (recommended once secrets are configured) — bump the version, push a tag, GitHub Actions does everything else.
- **Local `Scripts/release.sh`** — same outcome from your laptop, requires the Developer ID cert, notarization profile, and Sparkle EdDSA key in your Keychain plus SSH access to `PsyNeuView-releases`.

Both produce the same artifacts; the workflow file just calls the same scripts with credentials supplied via env vars.

---

## Release notes come from the tag message

Write the annotated tag message as the release notes. It is the single source for
three places, and all three used to say nothing useful:

| Where | Before |
|---|---|
| GitHub Release, private repo | a fixed template that still demanded "Python 3.9+, Node.js 18+, SSH key configured for GitHub" — none true since the app bundled its own |
| GitHub Release, public repo | one line: "Notarized macOS app. Hosted here so Sparkle can download it." |
| The in-app update dialog | nothing — the appcast had no `<description>`, so Sparkle offered a version number and no reason to install it |

`scripts/tag-notes.sh <tag>` prints the message; `--html` renders it for the
appcast. The release workflow calls both, so nothing needs assembling by hand.

What that means when tagging: **the message is the changelog**. Write it for
someone deciding whether to install, not for yourself later. Name who reported a
bug if someone did.

The first line becomes the release title, so keep it short and specific:
`PsyNeuView 0.5.5 — recovers from a broken install instead of stopping at one`.

**How to write the rest is in [docs/release-notes.md](docs/release-notes.md)** —
where the material comes from, what belongs in and what does not, the format the
renderer actually supports, and how to correct notes that are already published.
Read it before tagging; 0.5.12 shipped describing one of its twenty-one pull
requests because nobody had written any of this down (#159).

The short version: derive the notes from the range with
`scripts/draft-notes.sh <prev-tag> <new-tag> [repo-dir]` rather than from
memory, use sentence-lead paragraphs, and keep it plain text — the renderer
escapes markdown, so `**bold**` reaches users as literal asterisks.

## What a release must pass

A release reaches people who can't work around a broken build, so it is tested
in full, on the exact commit that ships (#174). `release.yml` runs all of this
before anything is signed or published, and stops at the first failure:

1. **The app's tests:** `swift build -c release` and `swift test`.
2. **The bundled PsyNeuView passed its full checks:**
   `scripts/check-psyneuview-tested.sh` looks up the pinned PsyNeuView
   revision and requires that it is on PsyNeuView's `devel` and that backend
   pytest (both Pythons), e2e, tutorials, typecheck and vitest all passed there
   (a suite that skipped itself because the push didn't touch its area counts
   as passing).
3. **A real install from the bundle:** `scripts/verify-bundled-install.sh`
   (venv from the bundled Python, dependency install, imports, the backend
   answering `/health`).
4. **The built app launches:** `scripts/measure-boot.sh` starts the app and
   waits for it to report a finished boot. On a machine that has never been
   set up (every CI runner), `PSYNEUVIEW_NONINTERACTIVE=1` makes that first
   launch install the bundled PsyNeuView with the wizard's defaults instead of
   waiting on the wizard, so CI allows it 15 minutes (`BOOT_TIMEOUT`). The
   boot time it checks is measured after the install. If it fails, it prints
   the end of the app's log. It also writes the launch step by step —
   unpacking, the environment, each phase of the package install, the
   server — to `.build/boot-breakdown.json`, kept as the run's
   `first-launch-breakdown` artifact, and `scripts/compare-boot-baseline.sh`
   warns when any step is more than 25% slower than
   `scripts/boot-baseline.json` (#215). What each step is tied to, and what
   would shrink it, is in [docs/startup-time.md](docs/startup-time.md);
   refresh the baseline from the artifact when a release changes the
   install deliberately.
5. **An older install moves to this PsyNeuView:** `scripts/check-bundle-upgrade.sh`
   plants an install stamped 0.0.1, points the app's saved setting at it, and
   launches again. The app must move to the PsyNeuView it carries by itself
   and start (#186). Until that existed, every app update left bundled users
   on the PsyNeuView they first installed.
6. **Edits to included models survive the move:**
   `scripts/check-working-copies-survive.sh` unpacks the bundle twice, plants
   an edited Reference Model in the "old" install's `backend/` (where working
   copies lived before PsyNeuView-archive#1319), starts the new install and requires
   the edit to be carried to `~/.psyneuview/working-copies`, to reopen with
   its edits, to stay put across a restart, and for a conflicting copy to be
   kept and reported (#217). It skips itself, with a notice, while the pinned
   PsyNeuView predates #1319 — a gate for a feature the bundle doesn't have
   is neither a pass nor a failure. Reuses the environment step 4 built.

The local fallback, `scripts/release.sh`, runs the same checks.

Two more levels need a person, and are written out in
[docs/testing.md](docs/testing.md): the **hand-test checklist**, run with the
test app (`make test-app`) on the commit to be tagged, before every release;
and the **fresh-user test** on a second macOS account, before a release that
touches setup, first launch or updates.

PsyNeuView is a public repository (since 2026-10-13; the older private history
is `jonhanke-nam/PsyNeuView-archive`), so fetching it and reading its test
results needs no token. The workflows use their own `GITHUB_TOKEN`, which only
raises the API rate limit. `PSYNEUVIEW_REPO_TOKEN` is optional and used only if
set. Step 2 reads the suites' results as Actions jobs: the check-runs API would
need Checks: Read, which a fine-grained personal token can't be given.

## Settings and native windows

Before a release, check nothing has grown a second Settings: the app has no
settings UI of its own, and Settings… (Cmd+,) must open PsyNeuView's Settings
in the app window. The rules — the app is a thin wrapper around the React app,
one control per setting, Mac-only settings in the **Mac app** section through
the `pnvSettings` bridge — are in the README's *Settings and native UI*
section, and `NativeWindowPolicyTests` (run by `swift test` above) enforces the
native-window list ([PsyNeuView-archive#1279](https://github.com/jonhanke-nam/PsyNeuView-archive/issues/1279)).

## Cutting a release (after secrets are set up)

Releases are cut from `jonhanke-devel`. `main` is dormant in this repo — the
last three tags (v0.5.8, v0.5.9, v0.5.10) all point at `jonhanke-devel` commits
that were never on `main`, and `scripts/check-release-freshness.sh` measures
against `jonhanke-devel` for the same reason.

```bash
# 1. Point the bundle at the PsyNeuView release it should ship.
#    scripts/psyneuview-pin.conf, PSYNEUVIEW_REF + PSYNEUVIEW_VERSION.
#
#    Check the tag's contents, not just its name: a tag cut before a version
#    bump merged still carries the old literal, and the app would then report
#    a version that disagrees with its own label.
git -C ../PsyNeuView show <tag>:backend/pyproject.toml | grep '^version'
#    And that it passed its full checks, before spending a release run on it:
./scripts/check-psyneuview-tested.sh

# 2. Bump the app version in Resources/Info.plist
#    Both CFBundleShortVersionString and CFBundleVersion. Commit on
#    jonhanke-devel.

# 3. Tag and push — this triggers .github/workflows/release.yml
git checkout jonhanke-devel
git tag -a v0.5.0 -m "PsyNeuView 0.5.0 — <what changed>"
git push origin v0.5.0
```

The tag must be **annotated**: its message is the release notes, per the section
above.

Watch the run at `https://github.com/jonhanke-nam/PsyNeuView-MacApp/actions`. On success you get:

- A new GitHub Release with the signed/notarized DMG attached
- A new `<item>` prepended to `PsyNeuView-releases/docs/appcast.xml`
- Existing Mac app installs pick up the update via Sparkle on next launch

If the workflow fails partway through, fix the cause, delete the failed release if any (`gh release delete vX.Y.Z`), delete the tag (`git push origin :refs/tags/vX.Y.Z`), then retag.

---

## One-time secrets setup

The workflow needs seven secrets in the MacApp repo (Settings → Secrets and variables → Actions). All values come from your local Keychain + Apple Developer account.

### 1. `DEVELOPER_ID_P12_BASE64` + `DEVELOPER_ID_P12_PASSWORD`

Export your "Developer ID Application" cert from Keychain Access:

1. Keychain Access → My Certificates → right-click the Developer ID Application cert → Export
2. Save as `DeveloperID.p12`, set a strong password (this becomes `DEVELOPER_ID_P12_PASSWORD`)
3. Base64-encode it:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```
4. Paste into `DEVELOPER_ID_P12_BASE64`. Delete the local `.p12` after.

### 2. `KEYCHAIN_PASSWORD`

Any random string — used only to lock the temporary build keychain on the runner. Generate one:

```bash
openssl rand -base64 32 | pbcopy
```

### 3. `NOTARY_APPLE_ID` + `NOTARY_TEAM_ID` + `NOTARY_PASSWORD`

- `NOTARY_APPLE_ID`: the Apple ID you submit notarization with (your developer account email).
- `NOTARY_TEAM_ID`: 10-character team ID from https://developer.apple.com/account → Membership.
- `NOTARY_PASSWORD`: an **app-specific password** generated at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords. Don't use your Apple ID password.

These are the same values you'd pass to `xcrun notarytool store-credentials` locally.

### 4. `SPARKLE_EDDSA_PRIVATE_KEY`

Export the Sparkle signing key from your Keychain. With Sparkle's tools already built (`swift build` in this repo populates them):

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /tmp/sparkle_priv.key
cat /tmp/sparkle_priv.key | pbcopy
```

Paste the contents (a single base64 line) into `SPARKLE_EDDSA_PRIVATE_KEY`. Delete `/tmp/sparkle_priv.key`.

The matching public key is already embedded in `Resources/Info.plist` as `SUPublicEDKey` — don't change it or existing installs won't accept the update.

### 5. `RELEASES_REPO_TOKEN`

The workflow has to push the appcast to a **separate** repo (`jonhanke-nam/PsyNeuView-releases`). The default `GITHUB_TOKEN` only works on the current repo, so you need a fine-grained PAT:

1. https://github.com/settings/personal-access-tokens → Generate new token
2. Resource owner: `jonhanke-nam`
3. Repository access: only `PsyNeuView-releases`
4. Permissions: Contents → Read and write
5. Copy the token, paste into `RELEASES_REPO_TOKEN`

Set a sensible expiration (e.g. 1 year) and add a calendar reminder to rotate.

---

## Verifying the setup without cutting a real release

Run the release workflow by hand: **Actions ▸ Release ▸ Run workflow**, on
`jonhanke-devel` or any branch. It runs every gate above (tests, the PsyNeuView
check, a real install, and launching an unsigned build of the app) and skips
signing, notarizing and everything that publishes. Do this before tagging
whenever the pin or the workflow has changed.

Signing and notarization only run on a real tag. If they fail, the failure mode
is "no DMG attached to the release" — recoverable by deleting the release/tag
and retrying once fixed.

---

## Falling back to local release

If CI is unavailable or you want to ship from your laptop, `./Scripts/release.sh` still works. It expects:

- Developer ID Application cert in your login Keychain
- `xcrun notarytool store-credentials "PsyNeuView" --apple-id ... --team-id ...` already run (creates the `PsyNeuView` Keychain profile)
- Sparkle EdDSA key in Keychain (`.build/artifacts/sparkle/Sparkle/bin/generate_keys` if it's not there)
- SSH access to `git@github.com:jonhanke-nam/PsyNeuView-releases.git`
- Run from `main` with no uncommitted changes
