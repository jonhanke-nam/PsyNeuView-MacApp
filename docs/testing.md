# Testing the Mac app

How the app is tested, from the checks every change gets to the one a
release gets by hand on a clean account (#209). The automated levels exist
and are described in [RELEASING.md](../RELEASING.md); this page adds the
two that need a person — a **test app that runs beside the real one** and a
**written checklist** — and says how to tell every running PsyNeuView apart.

## The testing ladder

| Level | What | When | Where |
|---|---|---|---|
| Per pull request | `swift build -c release`, `swift test`; `pnv-status --self-test`; a quick bundled install. PsyNeuView's own backend, end-to-end and tutorial suites run in its repo. | every change | `.github/workflows/build.yml` |
| Per release | the full gates on the exact commit: tests, the pinned PsyNeuView passed its suites, a real install from the bundle, the signed app launches on a never-set-up runner, an old install moves to the new PsyNeuView, edits survive the move, signing and notarization | every tag | `.github/workflows/release.yml`, [RELEASING.md](../RELEASING.md) |
| Hand test | the **test app** (`make test-app`) and the [checklist below](#the-hand-test-checklist) | before every release | this page |
| Fresh user | a **second macOS account** with a clean home and no developer tools: install the real DMG, Setup Wizard, first launch, an update from the previous version, Report a Problem — [steps below](#a-fresh-user-test-on-a-second-macos-account) | before a release that touches setup or updates | this page |
| Later, if wanted | a nightly job on a GitHub Mac runner that installs the latest release fresh and opens a model; a macOS virtual machine or self-hosted runner if that outgrows the runner | optional | — |

The policy behind the ladder: the minimum non-redundant tests to merge, the
full suites on every release, and most of all on every Mac app release — a
release reaches people who can't work around a broken build.

## The test app

`make test-app` builds **`.build/PsyNeuView Test.app`**: the same binary and
the same bundled Python, PsyNeuView and uv as `make app`, under a different
identity. The identity is the bundle id, `com.psyneuview.macapp.test`, and
everything else follows from it at run time (`Sources/PsyNeuView/Models/AppIdentity.swift`):

| | Real app | Test app |
|---|---|---|
| Bundle id, so preferences domain | `com.psyneuview.macapp` | `com.psyneuview.macapp.test` |
| Name, window title | PsyNeuView | PsyNeuView Test 0.5.19 |
| Icon | the logo | the logo with a red **TEST** ribbon |
| Application Support (PsyNeuView and its Python environment) | `~/Library/Application Support/PsyNeuView` | `~/Library/Application Support/PsyNeuView-Test` |
| Launch logs | `~/Library/Logs/PsyNeuView` | `~/Library/Logs/PsyNeuView-Test` |
| PsyNeuView settings file | `~/.psynewview.json` | `~/.psyneuview-test/psynewview.json` |
| PsyNeuLink clones, working copies, layouts, rescued models | `~/.psyneuview/…` | `~/.psyneuview-test/…` |
| Wizard's default checkout folder | `~/Documents/PsyNeuView` | `~/Documents/PsyNeuView-Test` |
| Default project folder (My Project Folder) | `~/Documents/PsyNeuView-My-Models` | `~/Documents/PsyNeuView-Test-Models` |
| GitHub grant in the Keychain | `com.psyneuview.macapp.github-token` | `com.psyneuview.macapp.test.github-token` |
| Sparkle | checks every 4 h | never runs; no feed in its Info.plist; the menu item says updates are off |

`AppIdentityTests` holds both identities side by side and fails if any path
is shared or nested. The real app sets none of these paths explicitly — its
folders are PsyNeuView's own defaults, exactly as before — so an existing
install is untouched by any of this.

**The project folder (#240).** The real app's default,
`~/Documents/PsyNeuView-My-Models`, is PsyNeuView's own and the app never
names it. The only way to point it elsewhere from outside is
`PSYNEWVIEW_MODELS_DIR`, and that *fixes* the folder — no Move…, no
one-time offer (#212) — which would make the test app unable to test those.
So before each start the test app writes `~/Documents/PsyNeuView-Test-Models`
as `model_dirs` in its own settings file (`AppIdentity.projectFolderSeed`),
the same setting Settings ▸ Folders ▸ Change… makes: it is filled in when
none is set, and pointed away when it names the real app's default or its
hidden `~/.psyneuview/models`. Only the setting changes; no file is moved,
and a folder you chose anywhere else is kept. The launch log says when it
does either. A test therefore never creates or changes files in your real
models folder. The one-time offer to move out of a legacy folder is not
testable in the test app: both the legacy folder and the offer's destination
are the real app's.

The Keychain grant, `~/Documents/PsyNeuView-Test-Models` and
`~/.psyneuview-test` are the only things a test leaves on your Mac; to start
over: `rm -rf ~/Library/Application\ Support/PsyNeuView-Test ~/.psyneuview-test
~/Library/Logs/PsyNeuView-Test && defaults delete com.psyneuview.macapp.test`
(and remove `~/Documents/PsyNeuView-Test-Models` once you've kept anything
in it you want).

```bash
GH_TOKEN=$(gh auth token) make test-app      # fetches the pinned PsyNeuView on first run
open ".build/PsyNeuView Test.app"            # beside the real app, which can stay open
```

Leave it in `.build`: Spotlight skips dot-folders, so it never appears in
Launchpad beside the real install (#118). If it asks to move to Applications,
say *Continue Without Moving*; moving it there is fine too — it lands as
`/Applications/PsyNeuView Test.app`, never over the real one.

### Every copy says what it is

- **Window title**: "PsyNeuView Test 0.5.19". The real app's title is
  "PsyNeuView", as it always was.
- **About** (PsyNeuView Test ▸ About): the first line names a test build with
  the commit it was built from — "PsyNeuView Test app 0.5.19, built from
  commit ec192ce — a test build (com.psyneuview.macapp.test)" — then the
  PsyNeuView and PsyNeuLink versions, then "Running from …" and "Data in …;
  settings under …". The real app's About gains the commit and the two
  location lines too.
- **Copy Diagnostics** (Development menu) and **Report a Problem** carry the
  same identity, version and commit.
- **The backend** is told `PSYNEUVIEW_APP_FLAVOR=release` or `test` by every
  launch, so PsyNeuView can show a "Test build" badge once it reads it (a
  PsyNeuView change; the variable is documented below).

### `PSYNEUVIEW_APP_FLAVOR`

Set by the app in the backend's environment on every launch, beside
`PSYNEUVIEW_DEPLOYMENT_MODE=mac_app`:

| Value | Meaning |
|---|---|
| `release` | the real app, `com.psyneuview.macapp` |
| `test` | the test app, `com.psyneuview.macapp.test` |

Unset means the backend was not launched by this app (`make start`, a
container). PsyNeuView does not read it yet; when it does, the intended use
is a "Test build" badge in the same visual language as the developer-mode
badge (PsyNeuView-archive#1291), and `/api/settings/info` reporting it so Report a
Problem's page diagnostics say it too. The test app also sets
`PSYNEUVIEW_CONFIG_FILE`, `PSYNEUVIEW_CLONE_ROOT`, `PSYNEWVIEW_WORKING_DIR`
and `PSYNEUVIEW_LAYOUTS_DIR` (the overrides PsyNeuView already honours) to
its own folders; the real app sets none of them.

## Which PsyNeuView is that? — `scripts/pnv-status`

```
$ scripts/pnv-status
PsyNeuView on this Mac — 2026-10-09 02:13:53

Mac apps
  (none)

Backends (uvicorn)
  pid 89371  port 52602  PsyNeuView 0.5.13
             ~/Documents/Code_Repositories/psyneulink_repos/DEVELOPMENT_FOLDERS/psyneuview-bugs-1244-1211-1094/backend
             since Fri Oct 9 02:13:59 2026; launched by: node …/node_modules/.bin/playwright test …

Development servers (vite)
  (none)

Containers
  (none)

Stop one with: pnv-status --stop <pid>
```

It lists every PsyNeuView running on the Mac: **Mac apps** (real app, test
app, or a `swift run` build; path, version, build commit, since when),
**backends** (port, PsyNeuView version read from `/openapi.json`, folder,
start time, the flavor and deployment mode from the process environment, and
which app or tool launched it — then a sweep of every listening port for
anything else answering as PsyNeuView, which is how a container's forwarded
port shows up), **vite dev servers** (PsyNeuView's only) and **containers**
(`podman ps` / `docker ps` when installed). `--stop <pid>` shows what the
pid is and asks before stopping it (`--yes` skips the question); stopping an
app stops its backend with it. Containers are stopped with the container
tool, and the line says how.

`pnv-status --self-test` runs the parsing — bundle id to flavor, `--port`
from a command line, `info.version` from an OpenAPI body, variables from
`ps -E` output, launcher kinds — against fixed inputs, and CI runs it on
every push. The script needs only what macOS ships (`ps`, `lsof`, `curl`,
`PlistBuddy`) and is written to be shellcheck-clean.

## The hand-test checklist

Run through this with the **test app** before every release, on the commit
that will be tagged. Each item names what was shipped and the issue that
shipped it, so a failure can be filed against the right thing. Tick them in
the release's pull request or tag notes.

Before starting: `scripts/pnv-status` shows nothing you didn't expect;
`make test-app` was built from the release commit (About shows the commit).

**Start checklist (#196, #215, #232)**
1. Quit and reopen the test app. The starting window shows the checklist
   with a step per phase — unpack, environment, PsyNeuLink, the backend's
   own phases (import, warm-up, ready) — each ticking off with its seconds,
   and an estimate of the time left on a long step.
2. The app window opens the moment the server answers, with no blank wait
   after the last tick.
3. Development ▸ View Logs shows the same steps with times; the last line of
   the start reads like "started in 38.2 s".

**Settings (#200, #205, PsyNeuView-archive#1279)**
4. ⌘, opens PsyNeuView's Settings inside the app window. There is no
   native settings window anywhere (the App menu's Settings… and the menu
   bar icon's Settings… both open the same page).
5. The **Mac app** rows are there and only there: General ▸ Mac app (restart
   PsyNeuView if it crashes; open PsyNeuView when you log in), Developer ▸
   which PsyNeuView runs (included with the app / a checkout), and Report a
   Problem's two settings (send with; send to). Change one, relaunch, and it
   is still changed.
6. Folders lists My Project Folder, your catalogs, the PsyNeuLink Library
   and Examples, and the included Reference and Demo models, each with
   Show in Finder.

**Switch to (#195, #186, PsyNeuView-archive#1303)**
7. Settings ▸ Developer ▸ Switch to: the dropdown lists *Another local
   checkout…*, *Another GitHub repo or branch…*, then the known sources in
   groups with counts, the one in use marked "✓ In use now". Apply & restart
   appears only for a valid choice that differs from what is installed.
8. Switch PsyNeuLink to a different source (PyPI if on GitHub, or the other
   way), Apply & restart. The start checklist shows the install, and About
   shows the new source and version afterwards. Switch back.
9. Developer ▸ which PsyNeuView runs: switch from the included PsyNeuView to
   a checkout and back (needs a checkout on disk; the wizard's default
   folder for the test app is `~/Documents/PsyNeuView-Test`). Nothing is
   deleted by either switch.

**First Steps (PsyNeuView-archive#1310)**
10. On a fresh test install, the first app window offers **PsyNeuView First
    Steps** (eight short walkthroughs). Decline it, relaunch: it is not
    offered again. Start it later from where PsyNeuView offers its
    walkthroughs: part 1 runs to its end inside the app window.

**Report a Problem (#202, #208)**
11. Help ▸ Report a Problem… opens the report screen in the Logs window.
    Type a description, Save Report: a `PNV-debugging-…` folder and a `.zip`
    land in Downloads, and Show in Finder reveals them.
12. The folder holds `report.md`, `diagnostics.json`, `logs.txt` (the whole
    launch), `logs-previous-launch.txt` when the launch was short,
    `page-state.json` and `activity.txt` from the page, and a screenshot
    of the app window. `report.md` names the test build, version and
    commit, where PsyNeuView runs from, the PsyNeuLink source and version,
    the start checklist with times, the last move to the included
    PsyNeuView, and every setting — with no token or password anywhere and
    your home folder shown as `~`.
13. Copy summary puts a short plain-text summary on the clipboard; the send
    option matches Settings ▸ Report a Problem ▸ send with.
14. Stop the server (Services ▸ Stop Services) and open Report a Problem
    again: it still works without the page, and says the server is stopped.

**Preferences surviving relaunch (#218)**
15. In the app, change something the page keeps: the Open menu's order, the
    pointer size, a collapsed panel. Quit, reopen. It is as you left it,
    even when the app came up on a different port (the Logs window says
    which port; Development ▸ Copy Backend URL shows it too).
16. Zoom the app window (View ▸ Zoom In) and the About window (⌘+ in
    About). Relaunch: both sizes are remembered.

**Edit your own checkout (#214, #195)**
17. Turn on developer mode in Settings. The App menu gains a Developer
    section with "Update PsyNeuView checkout (~/path @ branch)…", named for
    the folder and branch it would pull, enabled only when a checkout is
    running; the Development menu's developer items (Open Repo in Editor,
    Reveal Repo in Finder, Run Self-Check…) appear.
18. Running a checkout: edit a file in it, Services ▸ Restart Services, and
    the change is live. Turn developer mode off: the checkout item is
    hidden again, not greyed.

**Models folder Move… (#212, PsyNeuView-archive#1295)**
19. Settings ▸ Folders ▸ My Project Folder ▸ Move…: pick a new folder. The
    models move, the Open menu shows them from the new place, and the
    setting survives a relaunch. Move it back.
20. Save As writes into the project folder, never into the included
    PsyNeuView's own tree; after a relaunch the saved model is still in
    the Open menu.

**The test app itself (#209)**
21. The real app and the test app run at the same time; `scripts/pnv-status`
    lists both, each with its backend and "launched by the real app" /
    "launched by the test app".
22. The test app's About says it is a test build; its window title carries
    the version; its App menu's update item is greyed and says updates are
    off; nothing in `~/Library/Application Support/PsyNeuView`,
    `~/.psyneuview` or `~/.psynewview.json` changed while the test app ran
    (compare modification times before and after).
23. The test app's Settings ▸ Folders ▸ My Project Folder is
    `~/Documents/PsyNeuView-Test-Models`; a Save As lands there, and nothing
    in `~/Documents/PsyNeuView-My-Models` changed (#240).

**The page's dialogs (#243, PsyNeuView-archive#1392)**
24. Open a model, make an edit without saving, then open another model from
    the Open menu. A sheet on the app window asks "You have unsaved changes
    that will be lost. Load anyway?": Cancel keeps your model and edit, OK
    opens the other one. Before #243 nothing appeared and nothing opened.

**Afterwards**: `scripts/pnv-status` again; stop anything the test left
running.

## A fresh-user test on a second macOS account

Before a release that touches setup, first launch or updates. A second
account on the same Mac is a clean home folder, no developer tools, no
Python, no `gh` — exactly what a new user has — without a second machine.
It takes about half an hour, most of it waiting for the first launch.

**One-time setup of the account**

1. System Settings ▸ Users & Groups ▸ Add User: a Standard account named
   `pnvtest` (standard, not admin — a new user may not be one). Do not sign
   it in to iCloud.
2. Log in to it once so the home folder exists. Do **not** install Xcode,
   the Command Line Tools, Homebrew or Python there — the point is their
   absence. If `xcode-select -p` prints a path, the Command Line Tools are
   installed system-wide; that is fine, the app must work with or without
   them (#67), but note it in the result.
3. Put the previous release's DMG and the new release's DMG somewhere the
   account can read, for instance `/Users/Shared/`.

**The run**

4. **Install the previous release.** Log in as `pnvtest`. Open the previous
   DMG, drag PsyNeuView to Applications, eject. Open it from Applications.
   Gatekeeper must show no "damaged" or "unidentified developer" warning —
   this is the only literal test of notarization on a Mac that is not the
   build machine.
5. **Setup Wizard.** Leave every default. It must say PsyNeuView is included
   and need no GitHub sign-in. Press Launch. Note the time.
6. **First launch timing.** The starting window shows the checklist. Note
   when the app window opens; the Logs window's last start line says the
   total. Compare with [docs/startup-time.md](startup-time.md): about
   1 min 40 s on a fast Mac with a wired connection, 3–4 minutes on a
   managed laptop on Wi-Fi. Anything past 6 minutes is a finding even if it
   finishes; the app allows 10.
7. **It works.** Open a reference model from the Open menu, run it, and save
   a copy with Save As. Quit. Reopen: the saved copy is in the Open menu
   and the start takes seconds, not minutes.
8. **Update from the previous version.** PsyNeuView ▸ Check for App
   Updates… offers the new version (the appcast is public; this needs the
   release to be published, so do this step against the published release,
   or a dry run's DMG installed by hand in step 9). Install and relaunch.
   The start checklist shows the move to the new included PsyNeuView
   (#186); the saved copy from step 7 is still in the Open menu and still
   opens with its edits (#217); About shows the new version.
9. **Or install the new DMG over the old app** when the release is not
   published yet: open the new DMG, drag over the existing app, replace.
   Same checks as step 8.
10. **Report a Problem.** Help ▸ Report a Problem…, Save Report, then send it
    by the offered route (Mail must open pre-addressed, or the Gmail link
    must open the browser pre-addressed). The report's `report.md` must
    show the move in step 8 and the start checklist with times.
11. **Preferences survive.** Change the pointer size or the Open menu's
    order, quit, reopen: kept.

**Record** the macOS version, Mac model, the two app versions, the first
launch time, and anything that asked a question the user shouldn't have
been asked (a developer-tools dialog, a GitHub sign-in, a move prompt
after the app was already in Applications). File each as an issue with
the report folder from step 10 attached.

**Reset the account** for next time: delete `/Applications/PsyNeuView.app`,
`~/Library/Application Support/PsyNeuView`, `~/.psyneuview`,
`~/.psynewview.json`, `~/Library/Logs/PsyNeuView`, `~/Documents/PsyNeuView-My-Models`,
and `defaults delete com.psyneuview.macapp`. Or delete the account and make
it again, which is the cleaner reset.

## What the test app cannot test

- **Sparkle updates.** Off by design. The update path is covered by the
  fresh-user test (step 8) and by `check-bundle-upgrade.sh` in the release
  run.
- **Signing and notarization.** The test app is unsigned. Only a published
  DMG on a Mac that is not the build machine tests them (fresh-user step 4).
- **A different default project folder.** Shared with the real app until
  PsyNeuView has a default-only override; see above.
