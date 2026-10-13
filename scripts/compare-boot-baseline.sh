#!/usr/bin/env bash
# Print a launch's per-step breakdown and compare it with a recorded baseline (#215).
#
# Usage: scripts/compare-boot-baseline.sh <breakdown.json> [<baseline.json>]
#
# The breakdown is what measure-boot.sh and profile-first-launch.sh write:
#   { "source": …, "machine": {…}, "caches": "warm"|"cold", "totalSeconds": N,
#     "steps": [ { "id", "title", "seconds", "bytes" }, … ] }
# The baseline is a breakdown kept in the repo, scripts/boot-baseline.json,
# refreshed when a release is cut.
#
# A step counts as regressed when it is more than BOOT_REGRESSION_PERCENT (25)
# percent slower than the baseline AND at least two seconds slower — a 0.4 s
# step doubling is noise, a 120 s step gaining 30 s is not. Regressions are
# warnings (::warning:: on GitHub) unless BOOT_REGRESSION_FAIL=1, which makes
# this exit 1. A baseline from a different kind of machine or cache state is
# said so, and still compared: the ratio is what travels between machines.
set -euo pipefail

BREAKDOWN="${1:?breakdown.json}"
BASELINE="${2:-$(dirname "$0")/boot-baseline.json}"

python3 - "$BREAKDOWN" "$BASELINE" <<'PY'
import json, os, sys

breakdown_path, baseline_path = sys.argv[1], sys.argv[2]
percent = float(os.environ.get("BOOT_REGRESSION_PERCENT", "25"))
fail = os.environ.get("BOOT_REGRESSION_FAIL", "") == "1"

b = json.load(open(breakdown_path))
steps = b.get("steps") or []

def fmt_bytes(n):
    if n is None: return ""
    if n >= 1e9: return f"{n/1e9:.1f} GB"
    if n >= 1e6: return f"{n/1e6:.1f} MB"
    if n >= 1e3: return f"{n/1e3:.0f} kB"
    return f"{n} bytes"

print(f"boot: breakdown from {b.get('source', '?')} ({b.get('caches', '?')} caches), "
      f"total {b.get('totalSeconds', 0):.1f}s")
for s in steps:
    depth = s["id"].count("/")
    secs = s.get("seconds")
    text = f"{secs:8.1f}s" if secs is not None else "       —"
    extra = f"  {fmt_bytes(s.get('bytes'))}" if s.get("bytes") else ""
    print(f"  {text}  {'  ' * depth}{s.get('title', s['id'])}{extra}")

if not os.path.exists(baseline_path):
    print(f"boot: no baseline at {baseline_path}; nothing to compare")
    sys.exit(0)

base = json.load(open(baseline_path))
if (base.get("caches"), base.get("machine", {}).get("model")) != (b.get("caches"), b.get("machine", {}).get("model")):
    print(f"boot: baseline is from {base.get('machine', {}).get('model', '?')} with "
          f"{base.get('caches', '?')} caches; this run is {b.get('machine', {}).get('model', '?')} "
          f"with {b.get('caches', '?')} caches — comparing anyway, by ratio")

base_steps = {s["id"]: s for s in base.get("steps") or []}
regressed = []
def compare(label, now, then):
    if now is None or then is None: return
    if now > then * (1 + percent / 100) and now - then >= 2:
        regressed.append(f"{label}: {now:.1f}s, was {then:.1f}s (+{(now / then - 1) * 100:.0f}%)")

compare("total", b.get("totalSeconds"), base.get("totalSeconds"))
for s in steps:
    if s["id"] in base_steps:
        compare(s.get("title", s["id"]), s.get("seconds"), base_steps[s["id"]].get("seconds"))

if not regressed:
    print(f"boot: no step more than {percent:.0f}% slower than the baseline "
          f"({base.get('measuredAt', '?')}, {base.get('source', '?')})")
    sys.exit(0)
for line in regressed:
    print(f"::warning::first launch regressed — {line}")
    print(f"boot: REGRESSED {line}", file=sys.stderr)
sys.exit(1 if fail else 0)
PY
