#!/bin/bash
#
# Refuse to release a PsyNeuView that didn't pass its full checks (#174).
#
# The app bundles the PsyNeuView revision pinned in psyneuview-pin.conf. The Mac
# app's own tests say nothing about that code; PsyNeuView's suites do, and they
# run on every push to its devel. This asks GitHub what they concluded for the
# pinned commit, and fails unless:
#
#   - the commit is on devel (so it went through devel's gate), and
#   - every required suite finished and passed. "skipped" counts as passing:
#     each suite skips itself when a push touched nothing it covers, and the
#     code it covers was tested at the commit that last changed it.
#
# PsyNeuView is public, so no token is needed; gh uses GH_TOKEN when it is set
# (the workflow's own GITHUB_TOKEN is enough), which avoids anonymous rate limits.
#
# The results are read as Actions jobs, not check runs. They carry the same
# names and conclusions, but the check-runs API needs Checks: Read, which
# fine-grained personal tokens can't be given (only GitHub Apps can). Asking
# for it is how the first dry run failed.
#
# Usage: scripts/check-psyneuview-tested.sh [ref]   (default: the pinned ref)
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=psyneuview-pin.conf
source scripts/psyneuview-pin.conf
REPO="${PSYNEUVIEW_REPO}"
REF="${1:-$PSYNEUVIEW_REF}"

# The suites a PsyNeuView release must have passed. Names as GitHub reports them.
REQUIRED=(
  "backend pytest"
  "backend pytest (3.14)"
  "e2e"
  "tutorials"
  "typecheck (tsc)"
  "unit tests (vitest)"
)

fail() { echo "::error::$*" >&2; echo "✗ $*" >&2; exit 1; }

# The pin must be a release tag (see psyneuview-pin.conf): a commit ID would
# stop resolving if PsyNeuView's history were ever rebuilt.
if [ -z "${1:-}" ]; then
  gh api "repos/${REPO}/git/ref/tags/${REF}" --jq .ref >/dev/null 2>&1 \
    || fail "psyneuview-pin.conf pins '${REF}', which isn't a tag in ${REPO}. Pin a release tag (e.g. v0.6.0), not a commit or branch."
fi

SHA="$(gh api "repos/${REPO}/commits/${REF}" --jq .sha 2>/dev/null)" \
  || fail "Couldn't look up ${REF} in ${REPO}."
echo "PsyNeuView ${REF} is ${SHA:0:12}"

STATUS="$(gh api "repos/${REPO}/compare/${SHA}...devel" --jq .status)"
case "$STATUS" in
  ahead|identical) echo "  ✓ on devel" ;;
  *) fail "PsyNeuView ${REF} (${SHA:0:12}) is not on devel (compare says '${STATUS}'), so it never passed devel's gate." ;;
esac

# Every workflow run on the commit, newest first, then each run's jobs (the
# latest attempt of each, which is what the jobs API returns by default).
RUN_IDS="$(gh api "repos/${REPO}/actions/runs?head_sha=${SHA}&per_page=100" \
  --jq '.workflow_runs | sort_by(.created_at) | reverse | .[].id' 2>/dev/null)" \
  || fail "Couldn't read test results for ${SHA:0:12} in ${REPO}."
RUNS=""
for id in $RUN_IDS; do
  jobs="$(gh api "repos/${REPO}/actions/runs/${id}/jobs?per_page=100" \
    --jq '.jobs[] | [.name, .status, (.conclusion // "")] | @tsv' 2>/dev/null)" \
    || fail "Couldn't read the jobs of run ${id} in ${REPO}."
  RUNS+="${jobs}"$'\n'
done

bad=0
for name in "${REQUIRED[@]}"; do
  # A suite can run more than once on a commit (a re-run); the newest is listed first.
  line="$(printf '%s\n' "$RUNS" | awk -F'\t' -v n="$name" '$1 == n { print; exit }')"
  if [ -z "$line" ]; then
    echo "  ✗ ${name}: never ran on this commit"; bad=1; continue
  fi
  status="$(printf '%s' "$line" | cut -f2)"
  conclusion="$(printf '%s' "$line" | cut -f3)"
  if [ "$status" != "completed" ]; then
    echo "  ✗ ${name}: still ${status}"; bad=1
  elif [ "$conclusion" = "success" ] || [ "$conclusion" = "skipped" ]; then
    echo "  ✓ ${name}: ${conclusion}"
  else
    echo "  ✗ ${name}: ${conclusion}"; bad=1
  fi
done

[ "$bad" -eq 0 ] || fail "PsyNeuView ${REF} has not passed all its checks, so it can't ship in the app. Pin a revision that has."
echo "PsyNeuView ${REF} passed its full checks."
