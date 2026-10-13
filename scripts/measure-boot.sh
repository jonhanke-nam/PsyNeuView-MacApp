#!/usr/bin/env bash
# Measure how long the app takes to start, and fail if it is creeping toward
# the ceiling. (#104)
#
# 0.5.3 shipped a 30s ceiling against a 38.67s warm-up and nothing objected:
# the tests compared one constant to another, and every development machine had
# PsyNeuLink already imported. This launches the real app and measures.
#
# Usage: scripts/measure-boot.sh [max-fraction-of-ceiling]
#
# A CI runner is not a cold Mac, so the threshold is a *fraction* of the
# ceiling rather than a number of seconds — what transfers between machines is
# the ratio, not the duration.
#
# The app's report also carries the launch step by step (#215): on a first
# launch, unpacking, the environment, each phase of the package install, and
# the server. That breakdown is written to BOOT_BREAKDOWN (default
# .build/boot-breakdown.json, kept as a release artifact) and compared with
# scripts/boot-baseline.json by compare-boot-baseline.sh, which warns when a
# step is more than 25% slower (BOOT_REGRESSION_FAIL=1 to fail instead).
set -euo pipefail

MAX_FRACTION="${1:-0.25}"
APP=".build/PsyNeuView.app/Contents/MacOS/PsyNeuView"
REPORT="$(mktemp -t psyneuview-boot).json"
# The app's own log, mirrored to stderr when unattended; printed on failure so
# a check that fails says why rather than only that it waited (#174).
APP_LOG="$(mktemp -t psyneuview-boot-log)"
# On a machine that has never been set up, the first launch installs the
# bundled PsyNeuView before it starts (#174), which takes minutes. The boot
# measurement itself starts after the install, so a longer wait here doesn't
# loosen the timing check below.
TIMEOUT="${BOOT_TIMEOUT:-180}"
BREAKDOWN="${BOOT_BREAKDOWN:-.build/boot-breakdown.json}"

[ -x "$APP" ] || { echo "no app bundle — run 'make app' first" >&2; exit 2; }

cleanup() {
  pkill -f "$APP" 2>/dev/null || true
  rm -f "$REPORT" "$APP_LOG"
}
show_log() {
  echo "--- last lines of the app's log ---" >&2
  tail -n 60 "$APP_LOG" >&2 || true
}
trap cleanup EXIT

# NONINTERACTIVE or the launch stops on the relocation prompt and waits for a
# human that CI does not have.
PSYNEUVIEW_NONINTERACTIVE=1 PSYNEUVIEW_BOOT_REPORT="$REPORT" "$APP" >"$APP_LOG" 2>&1 &
APP_PID=$!
# The shell announces "Terminated" when the trap kills a job it is tracking;
# disowning keeps that noise out of CI output without losing the cleanup.
disown "$APP_PID" 2>/dev/null || true

waited=0
while [ ! -s "$REPORT" ]; do
  sleep 2
  waited=$((waited + 2))
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "boot: no report after ${TIMEOUT}s — the app never became healthy" >&2
    show_log
    exit 1
  fi
done

python3 - "$REPORT" "$MAX_FRACTION" <<'PY' || { show_log; exit 1; }
import json, sys
report, limit = sys.argv[1], float(sys.argv[2])
m = json.load(open(report))
seconds, ceiling, healthy = m["seconds"], m["ceiling"], m["healthy"]
fraction = seconds / ceiling if ceiling else 1.0

if not healthy:
    print(f"boot: FAILED after {seconds:.1f}s (ceiling {ceiling:.0f}s)")
    sys.exit(1)

print(f"boot: healthy in {seconds:.1f}s — {fraction * 100:.1f}% of the "
      f"{ceiling:.0f}s ceiling (limit {limit * 100:.0f}%)")

if fraction > limit:
    print("boot: too close to the ceiling — startup has slowed, or the ceiling "
          "is no longer generous enough", file=sys.stderr)
    sys.exit(1)
PY

# ── The launch step by step (#215) ──
#
# Written whether or not the app had steps to report: a launch without a
# checklist (nothing installed, server only) still records its total.
mkdir -p "$(dirname "$BREAKDOWN")"
python3 - "$REPORT" "$BREAKDOWN" "$APP" <<'PY'
import datetime, json, plistlib, subprocess, sys
report, out, app = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(report))
steps = m.get("steps") or []

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
def app_version():
    try:
        info = plistlib.load(open(app.replace("/MacOS/PsyNeuView", "/Info.plist"), "rb"))
        return info.get("CFBundleShortVersionString")
    except Exception:
        return None

top = [s for s in steps if "/" not in s["id"] and s.get("seconds") is not None]
total = sum(s["seconds"] for s in top) if top else m["seconds"]
breakdown = {
    "measuredAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": "measure-boot.sh",
    "machine": {"model": sysctl("hw.model"), "macOS": sw_vers(), "cpuCores": sysctl("hw.ncpu"),
                "chip": sysctl("machdep.cpu.brand_string")},
    "app": app_version(),
    # CI runners start empty; a developer Mac does not. Said here, because
    # the two are not comparable and the baseline check says which it has.
    "caches": "unknown",
    "healthSeconds": m["seconds"],
    "ceiling": m["ceiling"],
    "totalSeconds": total,
    "steps": steps,
}
json.dump(breakdown, open(out, "w"), indent=2)
print(f"boot: breakdown written to {out} ({len(steps)} steps)")
PY

./scripts/compare-boot-baseline.sh "$BREAKDOWN"
