#!/usr/bin/env bash
# Profile a first launch step by step, without the app (#215).
#
# measure-boot.sh times the real app, but needs a Mac that has never been set
# up — a CI runner. A developer's Mac already has the app's settings and an
# install, and wiping those to time a first launch is not something to do to
# someone's machine. So this runs the commands the app runs on a first launch
# — the same interpreter, uv, pip arguments and uvicorn launch, read off
# Installer and ProcessManager — in a throwaway folder, with a clock on each,
# and on each phase inside the package install, read from pip's and uv's
# output by the same rules as the app's InstallTimeline. It writes the same
# breakdown measure-boot.sh writes, so the two can be compared.
#
# Steps (ids match the app's checklist, ProgressStep; the parts under
# installPackages match InstallTimeline's ids):
#   getPsyNeuView      unpack the staged archive (BundledPsyNeuView.ensureUnpacked)
#   createEnvironment  python -m venv with the bundled interpreter (Installer.createVenv)
#   installPackages    uv pip install <PsyNeuLink source> (#224; pip with --pip),
#                      then uv pip install -e backend/ (Installer.installPythonDeps),
#                      each split by phase
#   prepareFastStart   compile bytecode and build matplotlib's font cache
#                      (FastStartPrep, #223), each timed
#   startServer        uvicorn until /health (ProcessManager)
#   firstModelLoad     POST /api/reference-models/load — not a checklist step,
#                      but the first thing a user does, and where PsyNeuLink
#                      is imported for the first time
#
# matplotlib's config folder is in the throwaway folder too (MPLCONFIGDIR), so
# the run is a Mac that has never run matplotlib — the font cache gets built,
# by the preparation step or, with --no-prepare, by the first server start —
# and the user's own ~/.matplotlib is never touched.
#
# Usage: scripts/profile-first-launch.sh [--cold] [--pnl <pip argument>] [--out <json>]
#   --cold        empty pip and uv caches, so every wheel is downloaded: a new
#                 Mac. Without it the caches on this Mac serve (uv's default
#                 ~/.cache/uv, not the app's own): a reinstall or an update.
#   --pnl         the PsyNeuLink source, as pip gets it. Default: the wizard's
#                 default, git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel
#   --pip         install PsyNeuLink with pip, as the app did before #224
#   --no-prepare  skip the fast-start preparation, as the app did before #223
#   --out         where to write the breakdown (default .build/first-launch-profile.json)
#   --keep        leave the throwaway folder (printed at the end) for a look at
#                 the environment: `pip show <package>` says who required what.
# CHECK_ARCHIVE / CHECK_PYTHON / CHECK_UV override the staged artefacts, as in
# check-working-copies-survive.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

COLD=0
KEEP=0
PNL_TOOL="uv"
PREPARE=1
PNL="git+https://github.com/PrincetonUniversity/PsyNeuLink.git@devel"
OUT=".build/first-launch-profile.json"
while [ $# -gt 0 ]; do
    case "$1" in
        --cold) COLD=1; shift ;;
        --pnl) PNL="${2:?}"; shift 2 ;;
        --pip) PNL_TOOL="pip"; shift ;;
        --no-prepare) PREPARE=0; shift ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

ARCHIVE="${CHECK_ARCHIVE:-$(ls Resources/psyneuview-*.tar.gz 2>/dev/null | head -1 || true)}"
[ -n "${ARCHIVE}" ] && [ -f "${ARCHIVE}" ] || { echo "no staged PsyNeuView archive — run 'make psyneuview-bundle' first" >&2; exit 1; }
if [ -n "${CHECK_PYTHON:-}" ]; then
    PYTHON="${CHECK_PYTHON}"
else
    RUNTIME="$(ls -d Resources/python-*/ 2>/dev/null | head -1 || true)"
    [ -n "${RUNTIME}" ] || { echo "no bundled Python — run 'make python-runtime' first" >&2; exit 1; }
    PYTHON="${PWD}/${RUNTIME%/}/bin/python3"
fi
if [ -n "${CHECK_UV:-}" ]; then
    UV="${CHECK_UV}"
else
    UV_DIR="$(ls -d Resources/uv-*/ 2>/dev/null | head -1 || true)"
    [ -n "${UV_DIR}" ] || { echo "no bundled uv — run 'make uv-runtime' first" >&2; exit 1; }
    UV="${PWD}/${UV_DIR%/}/uv"
fi

WORK="$(mktemp -d)"
BACKEND_PID=""
cleanup() {
    [ -n "${BACKEND_PID}" ] && kill "${BACKEND_PID}" 2>/dev/null || true
    if [ "${KEEP}" = "1" ]; then
        echo "kept ${WORK} (the environment is under Library/Application Support/PsyNeuView/*/backend/.venv)"
    else
        rm -rf "${WORK}"
    fi
}
trap cleanup EXIT

if [ "${COLD}" = "1" ]; then
    # Empty caches: pip and uv download every wheel, as on a new Mac.
    export PIP_CACHE_DIR="${WORK}/pip-cache" UV_CACHE_DIR="${WORK}/uv-cache"
    mkdir -p "${PIP_CACHE_DIR}" "${UV_CACHE_DIR}"
    CACHES="cold"
else
    CACHES="warm"
fi

now() { "${PYTHON}" -c 'import time; print(time.time())'; }
# Timestamp each line of an installer's output as it arrives, unbuffered.
STAMP="${WORK}/stamp.py"
cat > "${STAMP}" <<'PY'
import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f} {line}")
    sys.stdout.flush()
PY

# A Mac that has never run matplotlib (see the header).
export MPLCONFIGDIR="${WORK}/matplotlib"
mkdir -p "${MPLCONFIGDIR}"

NAME="$(basename "${ARCHIVE}" .tar.gz)"
PNV_VERSION="${NAME#psyneuview-}"
echo "Profiling a first launch of PsyNeuView ${PNV_VERSION} (${CACHES} caches)"
echo "  PsyNeuLink: ${PNL} (with ${PNL_TOOL})"
echo "  interpreter: ${PYTHON}"
echo "  uv: ${UV}"
[ "${PREPARE}" = "1" ] || echo "  fast-start preparation: skipped (--no-prepare)"
echo ""

TIMES="${WORK}/times.txt"      # "<id> <start> <end>" per step
mark() { echo "$1 $2 $3" >> "${TIMES}"; }

# ── getPsyNeuView: unpack, as BundledPsyNeuView.ensureUnpacked ──
SUPPORT="${WORK}/Library/Application Support/PsyNeuView"
mkdir -p "${SUPPORT}"
T0=$(now)
tar xzf "${ARCHIVE}" -C "${SUPPORT}"
T1=$(now)
mark getPsyNeuView "${T0}" "${T1}"
TREE="${SUPPORT}/${NAME}"
echo "  unpacked in $("${PYTHON}" -c "print(f'{${T1}-${T0}:.1f}')") s"

# ── createEnvironment: as Installer.createVenv ──
VENV="${TREE}/backend/.venv"
T0=$(now)
"${PYTHON}" -m venv "${VENV}"
T1=$(now)
mark createEnvironment "${T0}" "${T1}"
echo "  venv in $("${PYTHON}" -c "print(f'{${T1}-${T0}:.1f}')") s"

# ── installPackages: as Installer.installPythonDeps ──
# The app sets VIRTUAL_ENV and puts the venv's bin first, then, on a fresh
# venv with a non-PyPI source, installs PsyNeuLink FIRST (#115) — with the
# bundled uv since #224 (PsyNeuLinkInstall.command: the same arguments pip
# got, cloned from uv's cache), pip being the fallback — and the backend's
# packages after with the same uv (#94).
export VIRTUAL_ENV="${VENV}"
export PATH="${VENV}/bin:${PATH}"
BACKEND="${TREE}/backend"

if [ "${PNL_TOOL}" = "uv" ]; then
    echo "  uv pip install ${PNL} …"
    PNL_CMD=("${UV}" pip install --link-mode=clone "${PNL}")
else
    echo "  pip install ${PNL} …"
    PNL_CMD=("${VENV}/bin/pip" install "${PNL}")
fi
T0=$(now)
set +e
(cd "${BACKEND}" && "${PNL_CMD[@]}" 2>&1 | "${PYTHON}" -u "${STAMP}" > "${WORK}/pip-psyneulink.log")
PIP_EXIT=${PIPESTATUS[0]}
set -e
T1=$(now)
mark installPackages/psyneulink/total "${T0}" "${T1}"
[ "${PIP_EXIT}" = "0" ] || { echo "${PNL_TOOL} install failed (exit ${PIP_EXIT}); see ${WORK}/pip-psyneulink.log" >&2; tail -20 "${WORK}/pip-psyneulink.log" >&2; exit 1; }
echo "    done in $("${PYTHON}" -c "print(f'{${T1}-${T0}:.1f}')") s"

echo "  uv pip install -e backend/ …"
T2=$(now)
set +e
(cd "${BACKEND}" && "${UV}" pip install -e . 2>&1 | "${PYTHON}" -u "${STAMP}" > "${WORK}/uv-backend.log")
UV_EXIT=${PIPESTATUS[0]}
set -e
T3=$(now)
mark installPackages/backend/total "${T2}" "${T3}"
[ "${UV_EXIT}" = "0" ] || { echo "uv pip install failed (exit ${UV_EXIT}); see ${WORK}/uv-backend.log" >&2; tail -20 "${WORK}/uv-backend.log" >&2; exit 1; }
mark installPackages "${T0}" "${T3}"
echo "    done in $("${PYTHON}" -c "print(f'{${T3}-${T2}:.1f}')") s"

# ── prepareFastStart: as FastStartPrep.run (#223) ──
# The same two commands the app runs, with the environment the server gets
# (MPLCONFIGDIR included, so the font cache lands where the server reads it),
# under the app's rules: bytecode only when the install wrote packages (it
# always does here — the environment is new), the font cache only when the
# config folder has none (it never does here — the folder is new). In the
# app, a repair or an update on a Mac that is already prepared skips both and
# the step reads "already prepared"; this profile is a first launch.
if [ "${PREPARE}" = "1" ]; then
    T0=$(now)
    T1="${T0}"
    # The logs carry a timestamp before each line (STAMP).
    if /usr/bin/grep -qE "^[0-9.]+ +((Installed|Uninstalled) [1-9][0-9]* package|Installing collected packages)" \
            "${WORK}/pip-psyneulink.log" "${WORK}/uv-backend.log" 2>/dev/null; then
        SITE="$(ls -d "${VENV}"/lib/python*/site-packages | head -1)"
        echo "  compiling bytecode under $(basename "$(dirname "${SITE}")")/site-packages …"
        (cd "${BACKEND}" && "${VENV}/bin/python" -m compileall -q -j 0 "${SITE}" > "${WORK}/compileall.log" 2>&1) || \
            echo "    (compileall exited $?: $(wc -l < "${WORK}/compileall.log" | tr -d ' ') lines of output — normal for packages carrying code for other Pythons)"
        T1=$(now)
        mark prepareFastStart/compileBytecode "${T0}" "${T1}"
        echo "    done in $("${PYTHON}" -c "print(f'{${T1}-${T0}:.1f}')") s"
    else
        echo "  bytecode: packages unchanged — nothing to compile"
    fi
    T2=$(now)
    T3="${T2}"
    if ! ls "${MPLCONFIGDIR}"/fontlist-v*.json >/dev/null 2>&1; then
        echo "  building matplotlib's font cache …"
        (cd "${BACKEND}" && "${VENV}/bin/python" -c "import matplotlib.font_manager" > "${WORK}/fontcache.log" 2>&1) || \
            echo "    (font cache build exited $?; see ${WORK}/fontcache.log)"
        T3=$(now)
        mark prepareFastStart/fontCache "${T2}" "${T3}"
        echo "    done in $("${PYTHON}" -c "print(f'{${T3}-${T2}:.1f}')") s"
    else
        echo "  font cache: already built — nothing to do"
    fi
    mark prepareFastStart "${T0}" "${T3}"
fi

# ── startServer: as ProcessManager.startBackend ──
PORT="$("${PYTHON}" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
echo "  starting uvicorn on port ${PORT} …"
T0=$(now)
(cd "${BACKEND}" && exec env PSYNEUVIEW_DEPLOYMENT_MODE=mac_app PSYNEWVIEW_MODELS_DIR="${WORK}/models" \
    PSYNEUVIEW_CONFIG_FILE="${WORK}/psynewview.json" \
    "${VENV}/bin/python" -m uvicorn app.main:app --port "${PORT}" > "${WORK}/backend.log" 2>&1) &
BACKEND_PID=$!
disown "${BACKEND_PID}" 2>/dev/null || true
READY=0
for _ in $(seq 1 1200); do
    if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then READY=1; break; fi
    kill -0 "${BACKEND_PID}" 2>/dev/null || break
    sleep 0.5
done
T1=$(now)
[ "${READY}" = "1" ] || { echo "the backend never answered /health" >&2; tail -20 "${WORK}/backend.log" >&2; exit 1; }
mark startServer/health "${T0}" "${T1}"
# The window opens the moment /health answers (#226; the 3 s wait is gone).
mark startServer "${T0}" "${T1}"
echo "    /health in $("${PYTHON}" -c "print(f'{${T1}-${T0}:.1f}')") s"

# ── firstModelLoad: the first thing a user does ──
# The basic Stroop reference model, by whichever name this PsyNeuView uses:
# stroop_reference_basic, or stroop_basic_<a>_<b> before the rename (PsyNeuView-archive#1416).
REF_MODEL="$(curl -fsS "http://127.0.0.1:${PORT}/api/reference-models" | "${PYTHON}" -c '
import json, re, sys
names = [m["name"] for m in json.load(sys.stdin)["models"]]
print(next((n for n in names if n == "stroop_reference_basic"), None)
      or next(n for n in names if re.fullmatch(r"stroop_basic_[a-z]+_[a-z]+", n)))')"
echo "  loading a Reference Model (imports PsyNeuLink) …"
T0=$(now)
curl -fsS -X POST "http://127.0.0.1:${PORT}/api/reference-models/load" \
    -H 'Content-Type: application/json' -d "{\"name\":\"${REF_MODEL}\"}" > "${WORK}/load.json"
T1=$(now)
mark firstModelLoad "${T0}" "${T1}"
echo "    loaded in $("${PYTHON}" -c "print(f'{${T1}-${T0}:.1f}')") s"

PNL_VERSION="$("${VENV}/bin/pip" show psyneulink 2>/dev/null | sed -n 's/^Version: //p')"

# ── The breakdown ──
mkdir -p "$(dirname "${OUT}")"
"${PYTHON}" - "${TIMES}" "${WORK}/pip-psyneulink.log" "${WORK}/uv-backend.log" "${OUT}" \
    "${CACHES}" "${PNV_VERSION}" "${PNL}" "${PNL_VERSION:-?}" "${PNL_TOOL}" <<'PY'
import datetime, json, subprocess, sys

times_path, pip_log, uv_log, out, caches, pnv_version, pnl, pnl_version, pnl_tool = sys.argv[1:10]

times = {}
for line in open(times_path):
    sid, start, end = line.split()
    times[sid] = (float(start), float(end))

TITLES = {
    "getPsyNeuView": "Install PsyNeuView",
    "createEnvironment": "Create the Python environment",
    "installPackages": "Install PsyNeuLink and Python packages",
    "prepareFastStart": "Preparing Python for a fast first start",
    "prepareFastStart/compileBytecode": "Compiling Python bytecode",
    "prepareFastStart/fontCache": "Building matplotlib's font cache",
    "startServer": "Start the server and load PsyNeuLink",
    "startServer/health": "Server answered /health",
    "firstModelLoad": "First model load (imports PsyNeuLink)",
}
PHASE_TITLES = {
    "fetchSource": "fetch the source (git clone)",
    "buildMetadata": "read the package metadata",
    "resolveAndDownload": "resolve dependencies and download wheels",
    "buildWheel": "build the wheel",
    "install": "install the packages",
    "resolve": "resolve dependencies",
    "prepare": "download and prepare packages",
}

def size_bytes(text):
    parts = text.strip().split()
    if len(parts) != 2:
        return None
    try:
        n = float(parts[0])
    except ValueError:
        return None
    unit = {"bytes": 1, "b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9}.get(parts[1].lower())
    return int(round(n * unit)) if unit else None

def uv_seconds(text):
    total = 0.0
    for t in text.split():
        if t.endswith("ms"): total += float(t[:-2]) / 1000
        elif t.endswith("h"): total += float(t[:-1]) * 3600
        elif t.endswith("m"): total += float(t[:-1]) * 60
        elif t.endswith("s"): total += float(t[:-1])
        else: return None
    return total

def stamped(path):
    for raw in open(path, errors="replace"):
        ts, _, rest = raw.partition(" ")
        try:
            yield float(ts), rest.rstrip("\n")
        except ValueError:
            continue

def pip_phases(path, started, finished):
    """The rules of InstallTimeline.observe, for pip."""
    entries, downloads = [], []
    current = since = None
    phase_bytes = 0
    def transition(phase, now):
        nonlocal current, since, phase_bytes
        if current == phase:
            return
        if current is not None:
            entries.append({"phase": current, "seconds": now - since,
                            "bytes": phase_bytes if current == "resolveAndDownload" and phase_bytes > 0 else None})
        since = started if (not entries and current is None) else now
        current, phase_bytes = phase, 0
    for now, raw in stamped(path):
        line = raw.strip()
        if not line:
            continue
        if line.startswith("Cloning ") or (line.startswith("Resolved ") and " to commit " in line):
            transition("fetchSource", now)
        elif line.startswith(("Installing build dependencies", "Getting requirements to build",
                              "Preparing metadata", "Checking if build backend")):
            transition("buildMetadata", now)
        elif (line.startswith("Collecting ") and "git+" not in line) or line.startswith(
                ("Downloading ", "Using cached ", "Requirement already satisfied")):
            transition("resolveAndDownload", now)
            if line.startswith("Downloading ") and ".metadata " not in line and line.endswith(")"):
                name, _, size = line[len("Downloading "):].rpartition("(")
                b = size_bytes(size[:-1])
                if b is not None:
                    downloads.append((name.strip(), b))
                    phase_bytes += b
        elif line.startswith(("Building wheels for collected packages", "Building wheel for",
                              "Created wheel for", "Successfully built")):
            transition("buildWheel", now)
        elif line.startswith("Installing collected packages"):
            transition("install", now)
    if current is not None:
        entries.append({"phase": current, "seconds": finished - since,
                        "bytes": phase_bytes if current == "resolveAndDownload" and phase_bytes > 0 else None})
    downloads.sort(key=lambda d: -d[1])
    return entries, downloads

def uv_phases(path):
    entries = []
    for _, raw in stamped(path):
        words = raw.strip().split()
        if len(words) >= 5 and words[2].startswith("package") and words[3] == "in" and words[1].isdigit():
            phase = {"Resolved": "resolve", "Prepared": "prepare", "Installed": "install",
                     "Audited": "install", "Uninstalled": "install"}.get(words[0])
            secs = uv_seconds(" ".join(words[4:]))
            if phase and secs is not None:
                entries.append({"phase": phase, "seconds": secs, "bytes": None, "packages": int(words[1])})
    return entries

steps = []
def add(sid, title, seconds, bytes_=None):
    steps.append({"id": sid, "title": title, "seconds": round(seconds, 3), "bytes": bytes_})

add("getPsyNeuView", TITLES["getPsyNeuView"], times["getPsyNeuView"][1] - times["getPsyNeuView"][0])
add("createEnvironment", TITLES["createEnvironment"], times["createEnvironment"][1] - times["createEnvironment"][0])
add("installPackages", TITLES["installPackages"], times["installPackages"][1] - times["installPackages"][0])

pnl_label = f"PsyNeuLink ({pnl}) with {pnl_tool}"
p_start, p_end = times["installPackages/psyneulink/total"]
if pnl_tool == "pip":
    pip_entries, downloads = pip_phases(pip_log, p_start, p_end)
else:
    # uv prints no sizes without a terminal; its phases carry their own times.
    pip_entries, downloads = uv_phases(pip_log), []
for e in pip_entries:
    add(f"installPackages/psyneulink/{e['phase']}", f"{pnl_label}: {PHASE_TITLES[e['phase']]}", e["seconds"], e.get("bytes"))
total_bytes = sum(b for _, b in downloads)
add("installPackages/psyneulink/total", f"{pnl_label}: total", p_end - p_start, total_bytes or None)

b_start, b_end = times["installPackages/backend/total"]
for e in uv_phases(uv_log):
    add(f"installPackages/backend/{e['phase']}", f"Backend packages with uv: {PHASE_TITLES[e['phase']]}", e["seconds"])
add("installPackages/backend/total", "Backend packages with uv: total", b_end - b_start)

for sid in ("prepareFastStart", "prepareFastStart/compileBytecode", "prepareFastStart/fontCache"):
    if sid in times:
        add(sid, TITLES[sid], times[sid][1] - times[sid][0])

add("startServer", TITLES["startServer"], times["startServer"][1] - times["startServer"][0])
add("startServer/health", TITLES["startServer/health"], times["startServer/health"][1] - times["startServer/health"][0])
add("firstModelLoad", TITLES["firstModelLoad"], times["firstModelLoad"][1] - times["firstModelLoad"][0])

def sysctl(key):
    try:
        return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""
def sw_vers():
    try:
        return subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""

top = [s for s in steps if "/" not in s["id"]]
breakdown = {
    "measuredAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": "profile-first-launch.sh" + (" --cold" if caches == "cold" else ""),
    "machine": {"model": sysctl("hw.model"), "macOS": sw_vers(), "cpuCores": sysctl("hw.ncpu"),
                "chip": sysctl("machdep.cpu.brand_string")},
    "psyneuview": pnv_version,
    "psyneulink": {"source": pnl, "version": pnl_version},
    "caches": caches,
    "totalSeconds": round(sum(s["seconds"] for s in top), 3),
    "downloadedBytes": total_bytes or None,
    "largestWheels": [{"name": n, "bytes": b} for n, b in downloads[:10]],
    "steps": steps,
}
json.dump(breakdown, open(out, "w"), indent=2)
print("")
print(f"breakdown written to {out}")
PY

echo ""
./scripts/compare-boot-baseline.sh "${OUT}"
