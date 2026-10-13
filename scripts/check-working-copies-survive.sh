#!/bin/bash
#
# An edited Reference Model survives moving to a new included PsyNeuView (#217).
#
# Opening a Reference Model edits a working copy, not the bundled original.
# Until PsyNeuView-archive#1319 that copy lived in the running install's backend/ —
# a folder this app replaces when it moves to a new included PsyNeuView
# (#186) — so an update silently reopened the pristine model. PsyNeuView now
# keeps working copies in ~/.psyneuview/working-copies and carries old ones
# over at startup. This check plants an edit under the old rule, starts the
# NEW install beside the old one, and requires the edit to come through.
#
# Mirrors the app rather than reimplementing it, like verify-bundled-install.sh:
#   - unpacks the staged archive as BundledPsyNeuView.ensureUnpacked does, into
#     <home>/Library/Application Support/PsyNeuView/psyneuview-<version>
#   - builds the venv with the bundled interpreter and uv, as Installer does
#     (or reuses one already built from this archive: --venv)
#   - launches uvicorn the way ProcessManager does: PSYNEUVIEW_DEPLOYMENT_MODE
#     =mac_app, from the install's backend/, and waits for /health
#   - a throwaway HOME, so nothing touches the real ~/.psyneuview
#
# Skips, with a notice, when the bundled PsyNeuView predates #1319: the pinned
# version is what ships, and a check for a feature it doesn't have is neither a
# pass nor a failure. It also refuses to pass vacuously — step 10 proves the
# backend ran from a bundled tree, not a checkout.
#
# Usage: ./scripts/check-working-copies-survive.sh [--venv <path>]
#   --venv <path>  reuse backend/.venv of an install made from the SAME
#                  archive (release.yml passes the one the app's first launch
#                  built). Without it, the environment is built here, which is
#                  the slow part (minutes; seconds on a warm uv cache).
#
# Environment, for trying another staged archive without re-pinning:
#   CHECK_ARCHIVE  the psyneuview-<version>.tar.gz to test (default: Resources/)
#   CHECK_PYTHON   the interpreter to make the venv from (default: bundled)
#   CHECK_UV       the uv binary (default: bundled; pip when neither is found)
set -euo pipefail

cd "$(dirname "$0")/.."

REUSE_VENV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --venv) REUSE_VENV="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# Lines a Python check prints as "OK:…" / "BAD:…" are counted here; anything
# else is shown indented, as detail.
collect() {
    while IFS= read -r line; do
        case "$line" in
            OK:*)  ok "${line#OK:}" ;;
            BAD:*) bad "${line#BAD:}" ;;
            *)     echo "      $line" ;;
        esac
    done
}

WORK="$(mktemp -d)"
BACKEND_PID=""
stop_backend() {
    if [ -n "${BACKEND_PID}" ]; then
        kill "${BACKEND_PID}" 2>/dev/null || true
        # Give uvicorn its moment to let go of the port before the next start.
        for _ in $(seq 1 20); do
            kill -0 "${BACKEND_PID}" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "${BACKEND_PID}" 2>/dev/null || true
        BACKEND_PID=""
    fi
}
cleanup() {
    stop_backend
    rm -rf "${WORK}"
}
trap cleanup EXIT

echo "Checking that edits to included models survive an update..."
echo ""

# ── The artefacts a release carries ──
echo "Bundled artefacts:"
ARCHIVE="${CHECK_ARCHIVE:-$(ls Resources/psyneuview-*.tar.gz 2>/dev/null | head -1 || true)}"
if [ -z "${ARCHIVE}" ] || [ ! -f "${ARCHIVE}" ]; then
    echo "  ✗ no staged PsyNeuView archive — run 'make psyneuview-bundle' first" >&2
    exit 1
fi
ok "PsyNeuView archive staged ($(basename "${ARCHIVE}"))"

if [ -n "${CHECK_PYTHON:-}" ]; then
    PYTHON="${CHECK_PYTHON}"
else
    RUNTIME="$(ls -d Resources/python-*/ 2>/dev/null | head -1 || true)"
    [ -n "${RUNTIME}" ] || { echo "  ✗ no bundled Python — run 'make python-runtime' first" >&2; exit 1; }
    PYTHON="${PWD}/${RUNTIME%/}/bin/python3"
fi
check "interpreter runs (${PYTHON})" "'${PYTHON}' --version"

if [ -n "${CHECK_UV:-}" ]; then
    UV="${CHECK_UV}"
else
    UV_DIR="$(ls -d Resources/uv-*/ 2>/dev/null | head -1 || true)"
    UV=""
    [ -n "${UV_DIR}" ] && UV="${PWD}/${UV_DIR%/}/uv"
fi
if [ -n "${UV}" ]; then
    check "uv runs" "'${UV}' --version"
else
    echo "  — no uv; the install will fall back to pip"
fi

# ── Does this PsyNeuView have #1319 at all? ──
#
# Decided from the archive, before anything slow: the pinned release is what
# ships, and a release gate that burns ten minutes to say "not applicable"
# teaches people to skip it.
NAME="$(basename "${ARCHIVE}" .tar.gz)"           # psyneuview-<version>
VERSION="${NAME#psyneuview-}"
if ! tar tzf "${ARCHIVE}" | /usr/bin/grep -q "^${NAME}/backend/app/services/working_copies.py$"; then
    echo ""
    echo "  SKIPPED: the bundled PsyNeuView ${VERSION} predates PsyNeuView-archive#1319"
    echo "  (no backend/app/services/working_copies.py), so there is no working-copies"
    echo "  migration to check. The check runs in full once the pin moves to a"
    echo "  PsyNeuView that has it."
    echo ""
    echo "${FAIL} failed, ${PASS} passed, 1 skipped"
    exit 0
fi
ok "PsyNeuView ${VERSION} carries the working-copies migration (PsyNeuView-archive#1319)"

# ── Step 1: two installs side by side, as after an app update ──
echo ""
echo "Installs:"
HOME_TMP="${WORK}/home"
SUPPORT="${HOME_TMP}/Library/Application Support/PsyNeuView"
mkdir -p "${SUPPORT}" "${WORK}/models"

tar xzf "${ARCHIVE}" -C "${SUPPORT}"
NEW="${SUPPORT}/${NAME}"
check "new install unpacked (${NAME})" "test -f '${NEW}/backend/app/main.py' && test -f '${NEW}/BUNDLED_VERSION'"

OLD="${SUPPORT}/psyneuview-0.0.0-old"
mkdir -p "${WORK}/old"
tar xzf "${ARCHIVE}" -C "${WORK}/old"
mv "${WORK}/old/${NAME}" "${OLD}"
printf 'version=0.0.0-old\nref=upgrade-check\n' > "${OLD}/BUNDLED_VERSION"
check "old install planted (psyneuview-0.0.0-old)" "test -f '${OLD}/backend/app/main.py'"

# ── Step 2: an edit made under the old rule ──
MODEL="stroop_reference_basic"
# Bundles from before the rename (PsyNeuView-archive#1416) still use the old stem,
# stroop_basic_<a>_<b>; take whichever this bundle has.
if [ ! -f "${NEW}/backend/reference_models/${MODEL}.py" ]; then
    for f in "${NEW}"/backend/reference_models/stroop_basic_*_*.py; do
        [ -f "$f" ] && MODEL="$(basename "$f" .py)" && break
    done
fi
MARKER="# upgrade-check edit"
PRISTINE="${NEW}/backend/reference_models/${MODEL}.py"
[ -f "${PRISTINE}" ] || { bad "reference model ${MODEL}.py is not in the bundle"; exit 1; }
cp "${PRISTINE}" "${OLD}/backend/${MODEL}.py"
printf '\n%s\n' "${MARKER}" >> "${OLD}/backend/${MODEL}.py"
echo '{}' > "${OLD}/backend/${MODEL}.pnlview.json"
ok "edited ${MODEL}.py and its layout planted in the old install's backend/"
# What else is in there, so step 6 can prove nothing but the plant moved.
ls -1A "${OLD}/backend" | /usr/bin/grep -v -x -e "${MODEL}.py" -e "${MODEL}.pnlview.json" | sort > "${WORK}/old-backend-before.txt"
mkdir -p "${WORK}/old-backend-copy"
find "${OLD}/backend" -maxdepth 1 -type f -exec cp {} "${WORK}/old-backend-copy/" \;

# ── The environment, as Installer does (or the one it already made) ──
echo ""
echo "Environment:"
VENV=""
if [ -n "${REUSE_VENV}" ] && [ -x "${REUSE_VENV}/bin/python" ]; then
    VENV="${REUSE_VENV}"
    ok "reusing the environment at ${VENV}"
elif [ -n "${REUSE_VENV}" ]; then
    echo "  — no usable environment at ${REUSE_VENV}; building one"
fi
if [ -z "${VENV}" ]; then
    VENV="${NEW}/backend/.venv"
    check "venv created from the interpreter" "'${PYTHON}' -m venv '${VENV}'"
    START=$(date +%s)
    if [ -n "${UV}" ]; then
        if (cd "${NEW}/backend" && VIRTUAL_ENV="${VENV}" "${UV}" pip install -q -e . 2>&1 | tail -3); then
            ok "uv pip install -e backend/ succeeded ($(( $(date +%s) - START ))s)"
        else
            bad "uv pip install -e backend/ failed"; exit 1
        fi
    else
        if (cd "${NEW}/backend" && "${VENV}/bin/pip" install -q -e . 2>&1 | tail -3); then
            ok "pip install -e backend/ succeeded ($(( $(date +%s) - START ))s)"
        else
            bad "pip install -e backend/ failed"; exit 1
        fi
    fi
fi
check "psyneulink imports" "'${VENV}/bin/python' -c 'import psyneulink'"

# ── Launching, as ProcessManager does ──
#
# Everything the app sets, and nothing it doesn't: in particular NOT
# PSYNEWVIEW_WORKING_DIR, which would fix the folder and skip the migration —
# the very thing under test.
PORT=""
BOOTS=0
start_backend() {
    BOOTS=$((BOOTS + 1))
    PORT="$("${PYTHON}" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "  ✗ port ${PORT} is already in use; refusing to test against someone else's server" >&2
        exit 1
    fi
    # `exec` so $! is python itself, not a wrapper shell (see verify-bundled-install.sh).
    (cd "${NEW}/backend" && exec env -u PSYNEWVIEW_WORKING_DIR -u PSYNEUVIEW_BOOT_REPORT \
        HOME="${HOME_TMP}" \
        PSYNEUVIEW_DEPLOYMENT_MODE=mac_app \
        PSYNEWVIEW_MODELS_DIR="${WORK}/models" \
        PSYNEUVIEW_CONFIG_FILE="${HOME_TMP}/.psynewview.json" \
        VIRTUAL_ENV="${VENV}" PATH="${VENV}/bin:${PATH}" \
        "${VENV}/bin/python" -m uvicorn app.main:app --port "${PORT}" \
        >"${WORK}/backend-${BOOTS}.log" 2>&1) &
    BACKEND_PID=$!
    disown "${BACKEND_PID}" 2>/dev/null || true

    local began ready
    began=$(date +%s); ready=0
    for _ in $(seq 1 600); do
        if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then ready=1; break; fi
        if ! kill -0 "${BACKEND_PID}" 2>/dev/null; then break; fi
        sleep 1
    done
    if [ "${ready}" = "1" ]; then
        ok "backend ${BOOTS} answers /health ($(( $(date +%s) - began ))s)"
    else
        bad "backend ${BOOTS} never became ready — see below"
        tail -20 "${WORK}/backend-${BOOTS}.log" | sed 's/^/      /'
        exit 1
    fi
}
api() { curl -fsS "http://127.0.0.1:${PORT}/api/$1"; }
load_model() {
    curl -fsS -X POST "http://127.0.0.1:${PORT}/api/reference-models/load" \
        -H 'Content-Type: application/json' -d "{\"name\":\"${MODEL}\"}"
}

# The assertions on JSON, in one place. Each prints OK:/BAD: lines.
CHECKS="${WORK}/checks.py"
cat > "${CHECKS}" <<'PY'
import json, os, sys

def say(cond, msg):
    print(("OK:" if cond else "BAD:") + msg)
    return cond

def real(p):
    # The backend records resolved paths; on macOS /var is /private/var.
    return os.path.realpath(p) if p else p

def reals(paths):
    return [real(p) for p in (paths or [])]

phase = sys.argv[1]
WC = os.path.join(os.environ["HOME_TMP"], ".psyneuview", "working-copies")
SUPPORT = os.environ["SUPPORT"]
OLD_BACKEND = os.path.join(os.environ["OLD"], "backend")
NEW = os.environ["NEW"]
MODEL = os.environ["MODEL"]
MARKER = os.environ["MARKER"]

if phase == "after-first-boot":
    loc = json.load(open(sys.argv[2]))
    app = loc.get("appData") or {}
    # Step 4
    got = app.get("workingCopies")
    say(got == WC, f"workingCopies is {WC}" if got == WC else f"workingCopies is {got!r}, expected {WC}")
    say(got is not None and not got.startswith(SUPPORT + "/"), "working copies live outside Application Support")
    say(app.get("workingCopiesFixedBy") in (None, ""), "the folder was chosen by PsyNeuView, not fixed by PSYNEWVIEW_WORKING_DIR")
    # Step 5
    rec = app.get("workingCopiesLastMigration")
    if not say(isinstance(rec, dict), "a migration was recorded at startup"):
        print("  record: " + json.dumps(rec))
        sys.exit(0)
    say(rec.get("ok") is True, f"migration ok ({rec.get('ok')!r})")
    say((rec.get("moved") or 0) >= 2, f"moved >= 2 (moved {rec.get('moved')})")
    say(not rec.get("conflicts"), f"no conflicts ({rec.get('conflicts')})")
    say(not rec.get("failures"), f"no failures ({rec.get('failures')})")
    say(real(OLD_BACKEND) in reals(rec.get("from")), f"'from' names the old install's backend/ ({rec.get('from')})")
    say(real(rec.get("to")) == real(WC), f"'to' is the working-copies folder ({rec.get('to')})")
    # Step 6
    moved = os.path.join(WC, MODEL + ".py")
    say(os.path.isfile(moved) and MARKER in open(moved).read(), "the edited model is in working-copies, marker intact")
    say(os.path.isfile(os.path.join(WC, MODEL + ".pnlview.json")), "its layout sidecar came with it")
    say(not os.path.exists(os.path.join(OLD_BACKEND, MODEL + ".py")), "the edit is gone from the old install's backend/")
    say(not os.path.exists(os.path.join(OLD_BACKEND, MODEL + ".pnlview.json")), "so is its sidecar")
    before = set(open(sys.argv[3]).read().split("\n")) - {""}
    now = set(os.listdir(OLD_BACKEND))
    # PsyNeuView's own git tracks copies of the reference models at backend/
    # top level (identical to backend/reference_models/). A checkout's
    # migration leaves git-tracked files alone; a bundled install has no .git,
    # so it carries them over too. Pristine copies, so nothing is lost and no
    # model shows as edited — allowed here, and said out loud, because the
    # cleaner bundle is one that doesn't ship them.
    def pristine_of(name):
        for folder in ("reference_models", "demos"):
            path = os.path.join(NEW, "backend", folder, name)
            if os.path.isfile(path):
                return path
        return None
    shipped_pristine = set()
    for name in before:
        src = pristine_of(name)
        if src is None:
            continue
        old_copy = os.path.join(os.environ["WORK"], "old-backend-copy", name)
        if os.path.isfile(old_copy) and open(old_copy, "rb").read() == open(src, "rb").read():
            shipped_pristine.add(name)
    gone = before - now
    unexplained = gone - shipped_pristine
    say(not unexplained and not (now - before),
        "nothing else in the old backend/ moved" if not (gone - shipped_pristine) and not (now - before)
        else f"old backend/ changed: missing {sorted(unexplained)}, new {sorted(now - before)}")
    if gone & shipped_pristine:
        print(f"note: the bundle ships {len(gone & shipped_pristine)} pristine working copies at backend/ top level")
        print("      (PsyNeuView tracks them in git); the migration carried those over too.")
        print("      Harmless — identical to the reference models — but a bundle without them is cleaner.")
    # Step 10
    pnv = loc.get("psyneuview") or {}
    say(pnv.get("kind") == "included", f"psyneuview.kind == 'included' ({pnv.get('kind')!r}): the check ran from a bundled tree")
    say(os.path.realpath(pnv.get("path") or "") == os.path.realpath(NEW), f"psyneuview.path is the new install ({pnv.get('path')})")
    json.dump(rec, open(sys.argv[4], "w"), sort_keys=True)

elif phase == "after-load":
    resp = json.load(open(sys.argv[2]))
    fp = resp.get("file_path") or ""
    say(fp.startswith(WC + "/"), f"load opened the working copy under working-copies ({fp})")
    wc = resp.get("workingCopy") or {}
    say(wc.get("diverged") is True, f"workingCopy.diverged == true ({wc})")
    say(MARKER in (resp.get("source") or ""), "the source served carries the marker")

elif phase == "after-restart":
    loc = json.load(open(sys.argv[2]))
    rec = (loc.get("appData") or {}).get("workingCopiesLastMigration")
    first = json.load(open(sys.argv[3]))
    say(rec == first, "the migration record is unchanged after a restart (idempotent)"
        if rec == first else f"the record changed on restart: {json.dumps(rec)}")
    moved = os.path.join(WC, MODEL + ".py")
    say(os.path.isfile(moved) and MARKER in open(moved).read(), "the edit is still in working-copies")

elif phase == "after-conflict":
    loc = json.load(open(sys.argv[2]))
    rec = (loc.get("appData") or {}).get("workingCopiesLastMigration") or {}
    other = os.environ["OTHER"]
    old_file = os.path.join(OLD_BACKEND, other + ".py")
    new_file = os.path.join(WC, other + ".py")
    say(real(old_file) in reals(rec.get("conflicts")), f"the differing old copy is listed in conflicts ({rec.get('conflicts')})")
    say(rec.get("ok") is True and not rec.get("failures"), "a conflict is not a failure")
    say(os.path.isfile(old_file) and "# the older edit" in open(old_file).read(), "the old copy stays where it was")
    say(os.path.isfile(new_file) and "# the newer edit" in open(new_file).read(), "the copy already in working-copies is kept")
    say(os.path.isfile(os.path.join(WC, MODEL + ".py")), "the earlier migrated edit is untouched")
else:
    print("BAD:unknown phase " + phase)
PY
export HOME_TMP SUPPORT OLD NEW MODEL MARKER WORK

# ── Steps 3–7: the first start of the new install ──
echo ""
echo "First start of the new install (the migration runs here):"
start_backend
api locations > "${WORK}/locations-1.json"
collect < <("${PYTHON}" "${CHECKS}" after-first-boot "${WORK}/locations-1.json" \
    "${WORK}/old-backend-before.txt" "${WORK}/migration-1.json")

echo ""
echo "Opening the Reference Model (this imports PsyNeuLink; the first time is the slowest):"
if load_model > "${WORK}/load-1.json" 2>"${WORK}/load-1.err"; then
    collect < <("${PYTHON}" "${CHECKS}" after-load "${WORK}/load-1.json")
else
    bad "POST /api/reference-models/load failed"
    head -5 "${WORK}/load-1.err" | sed 's/^/      /'
fi

# ── Step 8: restart ──
echo ""
echo "Restart:"
stop_backend
start_backend
api locations > "${WORK}/locations-2.json"
collect < <("${PYTHON}" "${CHECKS}" after-restart "${WORK}/locations-2.json" "${WORK}/migration-1.json")
if load_model > "${WORK}/load-2.json" 2>/dev/null; then
    collect < <("${PYTHON}" "${CHECKS}" after-load "${WORK}/load-2.json")
else
    bad "POST /api/reference-models/load failed after the restart"
fi

# ── Step 9: a conflict keeps both and says so ──
echo ""
echo "Conflict (a different copy already in working-copies):"
stop_backend
OTHER="Cohen_Huston1994"
OTHER_PRISTINE="${NEW}/backend/reference_models/${OTHER}.py"
if [ -f "${OTHER_PRISTINE}" ]; then
    { cat "${OTHER_PRISTINE}"; printf '\n# the older edit\n'; } > "${OLD}/backend/${OTHER}.py"
    { cat "${OTHER_PRISTINE}"; printf '\n# the newer edit\n'; } > "${HOME_TMP}/.psyneuview/working-copies/${OTHER}.py"
    export OTHER
    start_backend
    api locations > "${WORK}/locations-3.json"
    collect < <("${PYTHON}" "${CHECKS}" after-conflict "${WORK}/locations-3.json")
else
    echo "  — no ${OTHER}.py in the bundle; conflict step skipped"
fi

echo ""
echo "${FAIL} failed, ${PASS} passed"
[ "${FAIL}" -eq 0 ]
