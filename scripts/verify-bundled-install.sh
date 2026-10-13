#!/bin/bash
#
# Exercise the bundled install the way a user's machine does, and fail the
# release if it doesn't work. (#45)
#
# 0.5.0 shipped unable to start from its own install directory. Every piece had
# tests — unpacking, signing, entitlements, the venv — but nothing walked the
# path from "setup finished" to "backend answering". This does.
#
# Mirrors the app rather than reimplementing it:
#   - unpacks the staged archive exactly as BundledPsyNeuView.ensureUnpacked does
#   - creates the venv with the BUNDLED interpreter, as Installer does
#   - launches uvicorn the way ProcessManager does, and waits for /health
#
# Usage: ./scripts/verify-bundled-install.sh [--quick]
#   --quick  stop after the tree checks; skip the ~10-minute dependency install
set -euo pipefail

cd "$(dirname "$0")/.."
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d)"
cleanup() {
    [ -n "${BACKEND_PID:-}" ] && kill "${BACKEND_PID}" 2>/dev/null || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

echo "Verifying the bundled install path..."
echo ""

# ── The artefacts a release carries ──
echo "Bundled artefacts:"
ARCHIVE="$(ls Resources/psyneuview-*.tar.gz 2>/dev/null | head -1 || true)"
RUNTIME="$(ls -d Resources/python-*/ 2>/dev/null | head -1 || true)"
if [ -z "${ARCHIVE}" ] || [ -z "${RUNTIME}" ]; then
    echo "  ✗ nothing staged — run 'make python-runtime psyneuview-bundle uv-runtime' first" >&2
    exit 1
fi
ok "PsyNeuView archive staged ($(basename "${ARCHIVE}"))"
ok "Python runtime staged ($(basename "${RUNTIME%/}"))"

PYTHON="${PWD}/${RUNTIME%/}/bin/python3"
check "bundled interpreter runs" "'${PYTHON}' --version"

UV_DIR="$(ls -d Resources/uv-*/ 2>/dev/null | head -1 || true)"
if [ -n "${UV_DIR}" ]; then
    UV="${PWD}/${UV_DIR%/}/uv"
    check "bundled uv runs" "'${UV}' --version"
else
    UV=""
    echo "  — no bundled uv; the install will fall back to pip"
fi

# ── Unpack, as the app does on first run ──
echo ""
echo "Unpacking:"
tar xzf "${ARCHIVE}" -C "${WORK}"
TREE="${WORK}/$(basename "${ARCHIVE}" .tar.gz)"
check "unpacks to a versioned directory" "test -d '${TREE}'"

# The two files isRunnableTree() requires. This is what 0.5.0 got wrong: it
# demanded a Makefile, which this tree deliberately does not ship.
check "backend/app/main.py present" "test -f '${TREE}/backend/app/main.py'"
check "frontend/dist/index.html present" "test -f '${TREE}/frontend/dist/index.html'"
check "reference models present" "test -d '${TREE}/backend/reference_models'"
if [ -f "${TREE}/Makefile" ]; then
    bad "Makefile must NOT ship — the app must not need one to start (#89)"
else
    ok "no Makefile, and the app must start anyway (#89)"
fi
check "no .git — nothing should run git against this (#87)" "test ! -e '${TREE}/.git'"

if [ "${QUICK}" = "1" ]; then
    echo ""
    echo "Quick mode: skipping dependency install and backend boot."
    echo "${FAIL} failed, ${PASS} passed"
    [ "${FAIL}" -eq 0 ]
    exit $?
fi

# ── Build the environment, as Installer does ──
echo ""
echo "Environment (this is the slow part):"
VENV="${TREE}/backend/.venv"
check "venv created from the bundled interpreter" "'${PYTHON}' -m venv '${VENV}'"
check "venv records the bundled interpreter" "grep -q \"$(dirname "${PYTHON}")\" '${VENV}/pyvenv.cfg'"

# Install the way the app does: bundled uv when present, pip otherwise. (#94)
if [ -n "${UV}" ]; then
    echo "  installing backend dependencies with the bundled uv..."
    START=$(date +%s)
    if (cd "${TREE}/backend" && VIRTUAL_ENV="${VENV}" "${UV}" pip install -q -e . 2>&1 | tail -3); then
        ok "uv pip install -e backend/ succeeded ($(( $(date +%s) - START ))s)"
    else
        bad "uv pip install -e backend/ failed"
    fi
else
    echo "  installing backend dependencies with pip (several minutes)..."
    if (cd "${TREE}/backend" && "${VENV}/bin/pip" install -q -e . 2>&1 | tail -3); then
        ok "pip install -e backend/ succeeded"
    else
        bad "pip install -e backend/ failed"
    fi
fi

# The hardened runtime's library validation would block these if the entitlement
# were missing or on the wrong binary. (#64)
check "numpy imports under the bundled interpreter" "'${VENV}/bin/python' -c 'import numpy'"
check "psyneulink imports" "'${VENV}/bin/python' -c 'import psyneulink'"

# ── Boot it, as ProcessManager does ──
echo ""
echo "Backend:"
# Pick a free port rather than a fixed one. A fixed port meant a leaked backend
# from an earlier run answered these checks — /health from memory, / as 404
# because its tree had been deleted — and the result described a process that no
# longer had any relationship to the code under test.
PORT="$("${PYTHON}" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  ✗ port ${PORT} is already in use; refusing to test against someone else's server" >&2
    exit 1
fi

# `exec` so the subshell is REPLACED by python: without it $! is the subshell's
# pid, cleanup kills the wrapper, and the real server is orphaned — which is
# exactly how the leak above happened.
(cd "${TREE}/backend" && exec "${VENV}/bin/python" -m uvicorn app.main:app --port "${PORT}" >"${WORK}/backend.log" 2>&1) &
BACKEND_PID=$!
disown "${BACKEND_PID}" 2>/dev/null || true

# Time the boot. This is the canary for a whole class of bug: 0.5.3 shipped with
# a 30-second ceiling against a 38.67-second PsyNeuLink warm-up, and nothing
# noticed because no test measured how long starting actually takes. (#104)
BOOT_START=$(date +%s)
READY=0
for _ in $(seq 1 600); do
    if curl -fsS "http://localhost:${PORT}/health" >/dev/null 2>&1; then READY=1; break; fi
    sleep 1
done
BOOT_SECONDS=$(( $(date +%s) - BOOT_START ))
if [ "${READY}" = "1" ]; then
    ok "backend answers /health (${BOOT_SECONDS}s)"

    # Compare what it actually took against what the app is configured to allow.
    # Reading the constants rather than restating them, so this cannot drift from
    # the values that ship.
    CONSTANTS="Sources/PsyNeuView/Utilities/Constants.swift"
    CEILING="$(grep -oE 'healthTimeout: TimeInterval = [0-9.]+' "${CONSTANTS}" | grep -oE '[0-9.]+$' | cut -d. -f1)"
    SLOW="$(grep -oE 'healthSlowAfter: TimeInterval = [0-9.]+' "${CONSTANTS}" | grep -oE '[0-9.]+$' | cut -d. -f1)"

    if [ -z "${CEILING}" ]; then
        bad "could not read healthTimeout from ${CONSTANTS}"
    elif [ "${BOOT_SECONDS}" -ge "${CEILING}" ]; then
        bad "startup took ${BOOT_SECONDS}s but the app gives up at ${CEILING}s — users will see a failure"
    elif [ "$(( BOOT_SECONDS * 4 ))" -ge "${CEILING}" ]; then
        bad "startup took ${BOOT_SECONDS}s against a ${CEILING}s ceiling — under 4x headroom, and a colder machine will be slower"
    else
        ok "startup headroom: ${BOOT_SECONDS}s against a ${CEILING}s ceiling"
    fi

    # CI runners are fast and warm. A user's first run is neither, so a boot slow
    # enough to trip the "still working" message here is worth knowing about.
    if [ -n "${SLOW}" ] && [ "${BOOT_SECONDS}" -ge "${SLOW}" ]; then
        echo "  ! startup took ${BOOT_SECONDS}s, past the ${SLOW}s point where the app starts reassuring the user."
        echo "    That is on a warm CI runner; a first run on a cold machine will be slower."
    fi
    # Match the hashed asset reference rather than markup containing quotes:
    # nesting escaped double quotes inside eval made this fail for reasons that
    # had nothing to do with the app. It also proves the *built* frontend is
    # being served, not merely some HTML.
    if curl -fsS "http://localhost:${PORT}/" | grep -q "assets/index-"; then
        ok "frontend is served from the bundled build"
    else
        bad "frontend is not served at /"
        curl -sS "http://localhost:${PORT}/" | head -3 | sed 's/^/      /'
    fi
else
    bad "backend never became ready — see below"
    tail -20 "${WORK}/backend.log" | sed 's/^/      /'
fi

echo ""
echo "${FAIL} failed, ${PASS} passed"
[ "${FAIL}" -eq 0 ]
