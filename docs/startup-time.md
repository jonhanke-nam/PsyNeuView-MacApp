# Where a first launch spends its time

A first launch — or the first launch after an app update that moves to a new
included PsyNeuView — installs a Python environment before the window
appears. This says how long that takes, what each second is tied to, how
much of it is the floor, and what would shrink the rest. The numbers are
measured, not estimated, and the tooling that measured them runs on every
release so they can't grow unnoticed (#215).

## The short version

**On a fast Mac with nothing cached, a first launch takes about 65 s
(it was 100–105 s before #223 and #224); a reinstall or an update with
everything cached, about 45 s.** Of the 65 s, a third is installing
PsyNeuLink and its dependencies — 183 packages, 359 MB downloaded, 1.7 GB
on disk, now fetched, resolved and written by the bundled uv in one pass —
a quarter is preparing Python so the first start is fast (bytecode and
matplotlib's font cache, done while the progress window is showing), and
most of the rest is the first start of the server, which on a Mac with
endpoint security is the security agent inspecting hundreds of freshly
written native extensions. A Mac with a slow connection pays more for the
download; 2–3 minutes is a fair expectation for a managed laptop on Wi-Fi.

**The floor with the current design is about 40 s**: unpacking PsyNeuView,
cloning PsyNeuLink, writing 1.7 GB of packages, and importing PsyNeuLink
once. Everything above that is network, bytes, and one-time file costs,
each of which has a fix below with a price.

## How it was measured

Two tools, writing the same per-step breakdown (`steps[]` with stable ids,
seconds and bytes):

- `scripts/measure-boot.sh` launches the real app on a Mac that has never
  been set up (every CI runner). The app times each step of its startup
  checklist (#196) and, inside "Install PsyNeuLink and Python packages",
  each phase of each pip and uv run, read from the installer's own output
  (`InstallTimeline`). The result goes into the boot report
  (`PSYNEUVIEW_BOOT_REPORT`), into `.build/boot-breakdown.json`, and into the
  release run's `first-launch-breakdown` artifact. The same per-step times
  are in Report a Problem (#202), so users' real timings reach us.
- `scripts/profile-first-launch.sh` runs the same commands the app runs — the
  bundled interpreter and uv, PsyNeuLink first (#115), the fast-start
  preparation, uvicorn — in a throwaway folder on a Mac that is already
  set up, with `--cold` to empty the pip and uv caches, and matplotlib's
  config folder inside the throwaway folder so the font cache is built
  (and timed) every run. `--pip` and `--no-prepare` reproduce the install
  before #224 and #223. It is how the numbers below were taken; a developer
  can rerun it in two minutes.

`scripts/compare-boot-baseline.sh` prints a breakdown and compares it with
`scripts/boot-baseline.json`; a step more than 25% and at least 2 s slower
is a `::warning::` in the release run (`BOOT_REGRESSION_FAIL=1` makes it
fail). The baseline is the cold run below. Refresh it from a release's
artifact when the install changes on purpose.

Measured 2026-10-09 with PsyNeuView 0.5.13 (the pin), PsyNeuLink
`PrincetonUniversity/PsyNeuLink@devel` (0.20.2.0+264, the wizard's default),
Python 3.14.7, uv 0.12.15, on a Mac16,5 (Apple M4 Max, 14 cores, 36 GB,
macOS 26.6.2, wired network; a JAMF-managed Mac with Cortex XDR), before
and after #223/#224 on the same morning. CI figures are from the four
release runs before #223/#224 on `macos-14`.

## The breakdown

Cold: every wheel downloaded, nothing cached (`profile-first-launch.sh --cold`).
Warm: uv's cache already holds every wheel and PsyNeuLink's repository — a
reinstall, a repair, or an update. Both on a Mac that has never run
matplotlib. "Before" is the same script with `--pip --no-prepare`: the
install as it was through 0.5.18 (the before figures include the 3 s wait
after `/health` that #226 dropped).

| Step | Cold | Warm | Before (cold / warm) | Tied to |
|---|---:|---:|---:|---|
| Install PsyNeuView (unpack the 2.4 MB archive) | 0.3 s | 0.2 s | 0.2 / 0.2 s | archive size |
| Create the Python environment (`python -m venv`) | 1.2 s | 1.3 s | 1.5 / 1.3 s | — |
| **Install PsyNeuLink and Python packages** | **22.1 s** | **1.8 s** | **64.1 / 43.4 s** | below |
| ├ PsyNeuLink with uv: resolve (fetch the repository, read its metadata, resolve the tree) | 11.4 s | 0.4 s | 11.4 s clone + 3.3 s metadata | PsyNeuLink's repository and the network |
| ├ PsyNeuLink with uv: download and prepare (359 MB of wheels, build PsyNeuLink's) | 8.4 s | — | 18.8 s + 3.9 s | the dependency tree, the network |
| ├ PsyNeuLink with uv: install the packages (clone 1.7 GB, 183 packages, from the cache) | 0.8 s | 0.7 s | 28.3 / 28.9 s | copy-on-write clones |
| └ Backend packages with uv (`uv pip install -e backend/`) | 1.2 s | 0.6 s | 2.3 / 1.3 s | everything already satisfied |
| **Preparing Python for a fast first start** | **15.0 s** | **15.3 s** | — | below |
| ├ Compile bytecode (`compileall -j 0` over site-packages) | 4.2 s | 4.3 s | (at first start) | 14 cores |
| └ Build matplotlib's font cache (`import matplotlib.font_manager`) | 10.8 s | 11.0 s | (at first start) | the fonts on this Mac |
| **Start the server and load PsyNeuLink** (to `/health`) | **25.3 s** | **23.9 s** | 36.6 / 35.4 s (+3 s) | endpoint security, below |
| First model load (`stroop_reference_basic`, worker already warm) | 0.7 s | 0.7 s | 0.7 / 0.7 s | — |
| **Total** | **~64 s** (64.7 and 63.3 s in two runs) | **~43 s** | **~106 / ~84 s** | |

A warm run whose wheel cache is full but whose git cache is empty (the
first run after upgrading to a build with #224, or a developer's
`~/.cache/uv`) spends 11 s in uv's resolve fetching PsyNeuLink's repository
once — the one-off uv pays to never clone it again — and takes 58 s.

The same first launch on GitHub's `macos-14` runner (M1, 3 cores, no
endpoint security; uv cache warm from the install check that runs just
before, pip cache cold): the whole "The built app launches" step took 77,
108, 109 and 112 s in the four release runs before #223/#224, and the
server answered `/health` in 5.1–5.6 s. The next release's
`first-launch-breakdown` artifact says what it is now.

### What the big steps are tied to

**Downloading 359 MB (19.5 s here; 30–60 s on a 50–100 Mbit connection).**
The ten largest wheels, and who asks for them:

| Wheel | Size | Required by |
|---|---:|---|
| torch 2.14.1 | 127.3 MB | PsyNeuLink (`requirements.txt`), for `AutodiffComposition`, PyTorch-backed learning and the Torch execution mode; 590 MB on disk, `libtorch_cpu.dylib` alone 368 MB |
| llvmlite 0.50 | 40.5 MB | PsyNeuLink, for the LLVM compiled execution modes |
| onnxruntime 1.30 | 21.5 MB | modeci_mdf (PsyNeuLink's MDF import/export) |
| scipy 1.18 | 20.5 MB | PsyNeuLink |
| jupyterlab 4.6 | 17.2 MB | `leabra-psyneulink` → `jupyter` (which also brings notebook, bokeh, ipykernel, tornado, …) |
| grpcio 1.84 | 12.3 MB | PsyNeuLink |
| pandas 3.0 | 10.2 MB | PsyNeuLink |
| babel 2.18 | 10.2 MB | jupyterlab |
| onnx 1.23 | 9.7 MB | modeci_mdf |
| matplotlib 3.11 | 9.3 MB | PsyNeuLink |

Two of these chains are worth knowing about. `leabra-psyneulink` (a
PsyNeuLink requirement) depends on `jupyter`, which pulls the whole
JupyterLab/notebook stack (~40 MB, ~50 packages) into every install, none of
which PsyNeuView uses. `modeci_mdf` brings `onnxruntime`, `onnx`, `skl2onnx`
and `h5py` (~35 MB). `optuna` brings SQLAlchemy and alembic. Together that is
roughly a quarter of the packages and a fifth of the bytes, all for features
PsyNeuView never exercises.

**Writing 1.7 GB to disk (was 27–30 s, cold or warm; now 0.8 s).** pip
unzipped 183 wheels into the venv, which did not shrink with caching — the
bytes had to land. Since #224 the bundled uv installs PsyNeuLink too, in
the same position (#115: the chosen source *first*, so the later
`uv pip install -e .` finds `psyneulink` satisfied and never downloads the
PyPI wheel), and uv keeps wheels unpacked in its cache and installs them
with `--link-mode=clone`: APFS copy-on-write clones, so the environment's
files share blocks with the cache until something writes to them. Not
hard links, which would make a file in site-packages and the cached copy
one inode (an in-place rewrite — pip refreshing a RECORD, say — would
change the cache) and fail across volumes; when a clone can't be made, uv
copies instead, which is what pip did. The cache is the app's own,
`~/Library/Application Support/PsyNeuView/uv-cache` (`UV_CACHE_DIR`), so a
repair or an update reuses every wheel and the environment costs almost no
extra disk. pip stays as the fallback: a uv failure is logged with its
exit code and the same install is retried with pip.

uv writes the same `direct_url.json` pip does — `vcs_info` with the commit
and requested revision for a git URL, `dir_info.editable` for a checkout —
checked against uv 0.12.15 — so PsyNeuView's Settings (`settings_info`)
and the app's About panel keep telling GitHub, PyPI and local installs
apart, and the freshness check (#116) still reads the installed commit.

**The git fetch (11.4 s cold, 0.4 s warm).** pip ran
`git clone --filter=blob:none` of PsyNeuLink (7–13 s) on every install and
reinstall, because pip does not cache git sources. uv fetches the
repository once into its cache (a full fetch of the branch — about 490 MB
with PsyNeuLink's history — so the first fetch costs what pip's blobless
clone did) and afterwards fetches only what moved: a branch update that
took pip minutes (#153) is a second with uv. versioneer still finds the
tags, so the version keeps its `+N.g<commit>` suffix.

**Build isolation and the wheel build (was 7.5 s cold, 1.6 s warm).** pip
built PsyNeuLink in an isolated environment, so it first installed
`setuptools` into a temporary venv, read the metadata, then built a
pure-Python wheel. uv does the same inside its resolve and prepare phases,
in parallel with the downloads, and caches the built wheel by commit.

**The first server start (36.6 s here before #223, 25.3 s after; 5–6 s on
CI).** uvicorn imports the app, then the lifespan starts the warm
PsyNeuLink worker and *waits for it* before answering `/health` — so this
step is the first `import psyneulink` (and torch) on a fresh environment.
Since #223 the install's last step, "Preparing Python for a fast first
start", compiles the bytecode (`python -m compileall -q -j 0
site-packages`, plus a local checkout installed editable) and builds
matplotlib's font cache (`python -c "import matplotlib.font_manager"`, run
with the environment the server gets, so the cache lands in
`~/.matplotlib` — or `$MPLCONFIGDIR` if the app was launched with one —
where the server reads it). That is 15 s moved out of the step the user
watches as "Still starting" into one with a name and a clock; failures
are logged and never fail the install. The step does only what is due:
bytecode is recompiled only when the install wrote or removed packages
(uv said `Installed N packages`, or pip reached `Installing collected
packages`; an `Audited` run changed nothing), and the font cache is built
only when the config folder has none, or it was built for a different
matplotlib — the version it was built for is stamped in
`~/Library/Application Support/PsyNeuView/matplotlib-font-cache.version`.
A repair or an update that changed nothing on a Mac that is already
prepared shows the step as "not needed (already prepared)" and spends no
time in it; the table's 15 s is a first launch. (Two runs that built the
font cache but, by a scripting slip, skipped the bytecode answered
`/health` in 28.3 and 28.4 s against 24–25 s with both — the 4 s the
compile is worth, measured by accident.) Measured piece by piece on the
same environment, before #223:

| What | Measured |
|---|---:|
| Import PsyNeuLink, bytecode already compiled, files already loaded once | 1.5–2.0 s |
| … with every `__pycache__` removed (compiling bytecode for 183 packages) | 5.5 s (worker to ready: 6.0 s) |
| … plus matplotlib building its font cache (a Mac with no `~/.matplotlib`) | 14.8 s |
| First import right after install, on this Mac | 22.7 s |
| `import torch` alone: first time after install / second time | 4.4 s / 0.4 s |

The gap between 6 s and 22.7 s is the first load of freshly written files
on a Mac with endpoint security: Cortex XDR inspects each new binary as it
is first mapped, and the environment has hundreds of native extensions
(torch's dylibs are 400 MB of them). GitHub's runners have no such agent and
answer `/health` in 5–6 s from the same install; a user's managed laptop
behaves like this Mac. The font cache is a separate one-time cost on a Mac
that has never run matplotlib: 8.5–11 s, paid again whenever matplotlib's
major version changes — now paid in the preparation step. What is left
in the first start after #223 (24–25 s here, three runs) is the security
agent; a Mac without one should see the 5–6 s CI does.

The app used to wait a fixed 3 s after `/health` before showing the window
(`ProcessManager.notifyReady`, "give the warm worker time") — which the
server already guaranteed by waiting for the worker itself. Dropped in
#226: the window opens the moment `/health` answers.

### What the starting window shows (#232)

Every start is a checklist, not a spinner. A checkout start lists
*Updating your checkout*, *Checking interface packages*, *Rebuilding the
interface* and *Updating Python packages* before the server; every start
lists *Starting the server*, *Loading PsyNeuLink* and *Warming up the
model runner*, with *Installing the PsyNeuLink update* inserted only when
the backend begins one. A step that isn't needed is shown as skipped with
its reason ("already up to date", "no interface changes"); a running step
shows its elapsed time and "usually about N s" from this Mac's own
previous launches. The server steps follow the backend's phase lines
(`PNV-START <phase> <event> [elapsed=<s>] [detail=…]` on its stdout);
a backend that prints none gets one *Starting the server* step to
`/health`. A checkout start rebuilds the interface only when the pull
changed a file under `frontend/` (or the build is missing or older than
the sources), runs `npm install` only when the package lists changed or
`node_modules` is missing, and reinstalls Python packages only when
`backend/pyproject.toml` changed (`CheckoutRefresh`). After a step that
wrote new packages, a server start past 15 s says why it is slow (#228).
All of these steps are in the boot report and Report a Problem.

### A typical user Mac

Scaling the measured pieces rather than guessing: a two-year-old MacBook
Air on 100 Mbit Wi-Fi, managed by the university, with nothing cached:

| | |
|---|---:|
| Fetch PsyNeuLink's repository | 15–25 s |
| Download 359 MB | 35–60 s |
| Write the packages, build the wheel, metadata | 5–10 s |
| Prepare the first start (bytecode on 8 cores, font cache) | 20–30 s |
| First server start (endpoint security) | 25–35 s |
| Everything else | ~5 s |
| **First launch** | **2–2½ minutes** (3–3½ before #223/#224) |

On the same Mac without endpoint security, or on a second install (caches
warm), about 1 minute. The 15-minute `BOOT_TIMEOUT` the release run allows
is generous by 6x, which is right for a laptop on hotel Wi-Fi.

## The floor

What cannot be avoided while PsyNeuView installs PsyNeuLink from source
into a fresh environment on the user's Mac: unpack (0.3 s), venv (1.2 s),
clone (~7 s on a good connection), write the packages it genuinely needs
(torch, numpy, scipy, llvmlite, matplotlib, pandas, graph-scheduler and the
small ones — about 1.2 GB, ~20 s), import PsyNeuLink once (~6 s with
bytecode compilation). **About 35–40 s on a fast Mac, double that on a slow
one.** The 65 s now is 1.6x the floor (it was 2.5x); on this Mac the
difference is mostly the security agent's first look at the native
extensions, and then the network.

## What would shrink it, ranked

Each with the saving on the cold run above and what it costs.

1. ~~**Compile bytecode and warm the font cache during the install, not at
   first start.**~~ Done (#223): "Preparing Python for a fast first start"
   is the install's last step. Measured: 15 s in the step (4.2 s bytecode
   on 14 cores, 10.8 s font cache), 11 s off the first server start on
   this Mac — the rest of that step is endpoint security, which no amount
   of preparation moves. Net cost of 4 s on the total here, in exchange
   for the slowest-feeling step being shorter and the work having a name.

2. ~~**Install PsyNeuLink with uv too (one resolver, hard links from the
   cache).**~~ Done (#224), with copy-on-write clones rather than hard
   links (see "Writing 1.7 GB to disk" above for why). Measured: the
   install step from 64 s to 22 s cold, 43 s to 2 s warm; pip remains the
   fallback and `settings_info` still reads `github`/`editable` from the
   `direct_url.json` uv writes.

3. **Install PsyNeuLink from a CI-built wheel instead of a git clone.** A
   wheel of `devel` built by PsyNeuLink's own CI (or by this repo's release
   run, pinned like `psyneuview-pin.conf`) removes the clone (7–13 s), the
   isolated build (3 s) and the wheel build (4 s), and makes installs
   reproducible — "devel" stops meaning "whatever it was that day" (#47).
   Cost: somewhere to publish the wheel (a GitHub release asset works), a
   pin to bump, and the backend's "is PsyNeuLink behind devel?" check (#116)
   has to read the wheel's recorded commit rather than a clone's.
   *Saves 15–20 s; cost: a few days across both repos.*

4. **Stop installing what nothing uses.** The jupyter stack (via
   `leabra-psyneulink`), onnxruntime/onnx/skl2onnx/h5py (via `modeci_mdf`)
   and optuna's SQLAlchemy/alembic are ~75 MB downloaded and ~300 MB on
   disk. Either PsyNeuLink moves them to extras upstream (the right fix:
   `leabra-psyneulink[jupyter]`, `psyneulink[mdf]`), or the app installs
   PsyNeuLink with `--no-deps` from an explicit, trimmed requirement list
   it maintains — which is a maintenance burden and a divergence from what
   PsyNeuLink's own tests run against. Torch is *not* on this list: it is
   imported at module level by `component.py` and `function.py`, so
   PsyNeuLink does not import without it today. Deferring torch would need
   upstream work to make the import lazy, after which it could be installed
   on first use of a learning feature (saving 127 MB / 590 MB and ~10 s).
   *Saves 10–15 s now, 20–25 s with torch deferred; cost: upstream PRs,
   maintainer agreement, and a feature that installs on demand.*

5. **Ship a prebuilt environment in the app.** Bundling the whole venv
   (1.7 GB; ~500 MB compressed) makes a first launch ~15 s: unpack, relink,
   start. It also turns the DMG from 120 MB into 600+ MB, fixes PsyNeuLink
   to whatever was built (the "choose a source" wizard becomes "or install
   a different one, slowly"), and has to be rebuilt and re-notarised per
   Python and per PsyNeuLink. The relocatability of a venv is solvable
   (`uv` can build relocatable ones) but every native extension has to be
   signed inside the app bundle for the hardened runtime. *Saves 80 s;
   cost: a week, a much larger download, and a design change the user
   sees.* Worth it only if the measured first launch on real user Macs
   (Report a Problem now carries it) says the 2–3 minutes are losing people.

6. **Show the window sooner.** The 3 s wait after `/health` is dead time
   now that the server only answers once the worker is warm (the comment
   in `notifyReady` predates that). The first start could also show the
   frontend while the warm worker is still importing, if the backend
   answered `/health` before the worker and the UI tolerated a slow first
   model open. *Saves 3 s for one line; 20+ s more on a managed Mac with a
   larger UI change.*

1, 2 and 6 together took the cold run from ~99 s to ~65 s on this Mac; 3
would take another 10–15 s off (the fetch and the build), leaving the
security agent's share, which only a Mac without one avoids.

## Keeping it this way

- `measure-boot.sh` writes the breakdown and compares it with the baseline
  on every release; a slower step is a warning in the run's annotations.
  Make it a failure (`BOOT_REGRESSION_FAIL=1` in `release.yml`) once a few
  releases have shown the CI numbers are stable enough not to cry wolf.
- The release notes should carry one line from the artifact: "first launch
  on the release runner: 1 m 49 s, of which PsyNeuLink 1 m 10 s". Not yet
  automated — `draft-notes.sh` could read `boot-breakdown.json`.
- Report a Problem (#202) now includes the per-step and per-phase times, so
  a "it took forever" report says which step.

## Proposed follow-up issues (not filed)

1. ~~Compile bytecode and build the matplotlib font cache during the install
   (option 1).~~ Done (#223).
2. ~~Install PsyNeuLink with the bundled uv, keeping #115's ordering (option
   2).~~ Done (#224).
3. Pin PsyNeuLink to a CI-built wheel of devel instead of a git clone
   (option 3; touches PsyNeuView's freshness check #116 and the pin
   convention from #47).
4. Upstream to PsyNeuLink: move `jupyter` (via leabra-psyneulink) and the
   MDF/ONNX stack behind extras; make the torch import lazy (option 4).
   Needs maintainer discussion; file in the fork first.
5. ~~Drop the fixed 3 s wait after `/health` in `ProcessManager.notifyReady`
   (option 6, first half) — the server already waits for the worker.~~
   Done (#226).
6. Put the first-launch line in the release notes from the artifact
   (`draft-notes.sh` reading `boot-breakdown.json`), and switch the
   baseline comparison from warn to fail after a few stable releases.
7. ~~Say "Still starting" less vaguely on a managed Mac: when the first start
   is slow because endpoint security is inspecting new files, say so
   (detectable: first start after an install, `/health` past 15 s).~~
   Done (#228, #232): the starting window says so once the server start
   passes 15 s after a step that wrote new packages.
