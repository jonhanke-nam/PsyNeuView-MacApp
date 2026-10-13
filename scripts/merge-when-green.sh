#!/usr/bin/env bash
# Merge a pull request once its checks pass -- and refuse when there are none.
#
# "Merge when green" is vacuous against an empty set. GitHub can decline to
# create a check suite at all: the pull request sits at zero checks, which looks
# exactly like checks-not-yet-started, and a naive poller eventually gives up
# waiting and merges something nothing ever tested.
#
# That happened on #163. Actions was healthy and an identical pull request had
# built twenty minutes earlier; this one simply never got a check suite.
# Closing and reopening re-fired the event and the build appeared.
#
# This script treats "no checks" as a failure to report, never a green to merge.
# The real fix is required status checks on the branch (#55), which makes the
# guard server-side instead of advisory -- until then, this is the guard.
#
# Usage: merge-when-green.sh <pr> [-R owner/repo] [--refire] [--timeout SECONDS]
set -uo pipefail

PR=""; REPO=""; REFIRE=0; TIMEOUT=2400; GRACE=120
while [ $# -gt 0 ]; do
    case "$1" in
        -R|--repo)  REPO="$2"; shift 2 ;;
        --refire)   REFIRE=1; shift ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          PR="$1"; shift ;;
    esac
done
[ -n "$PR" ] || { echo "usage: $(basename "$0") <pr> [-R owner/repo] [--refire]" >&2; exit 2; }
# bash 3.2 (macOS) treats "${arr[@]}" on an empty array as unbound under
# set -u, so every expansion uses the +alternate form.
GH_ARGS=(); [ -n "$REPO" ] && GH_ARGS=(--repo "$REPO")
gha() { printf '%s\n' ${GH_ARGS[@]+${GH_ARGS[@]+"${GH_ARGS[@]}"}}; }

say() { printf '%s\n' "$*"; }

rollup() {
    # One API call, parsed into four fields. A single-line jq deliberately:
    # backslash line-continuations inside a jq string literal are a parse error,
    # which silently made an earlier version of this script unable to read any
    # pull request at all.
    local json
    json="$(gh pr view "$PR" ${GH_ARGS[@]+"${GH_ARGS[@]}"} --json state,statusCheckRollup 2>/dev/null)" || return 1
    [ -n "$json" ] || return 1
    printf '%s' "$json" | jq -r '[.state, ([.statusCheckRollup[]] | map(select(.status != "COMPLETED")) | length), ([.statusCheckRollup[]] | map(select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT")) | length), ([.statusCheckRollup[]] | length)] | @tsv'
}

refired=0
started=$(date +%s)

while :; do
    IFS=$'\t' read -r state pending failing total <<< "$(rollup)"
    [ -z "${state:-}" ] && { say "could not read pull request $PR"; exit 1; }
    [ "$state" = "MERGED" ] && { say "already merged"; exit 0; }
    [ "$state" = "CLOSED" ] && { say "pull request is closed -- not merging"; exit 1; }

    elapsed=$(( $(date +%s) - started ))

    if [ "${failing:-0}" -gt 0 ]; then
        say "NOT MERGING -- ${failing} check(s) failing:"
        gh pr view "$PR" ${GH_ARGS[@]+"${GH_ARGS[@]}"} --json statusCheckRollup --jq \
          '.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT") | "  \(.conclusion)  \(.name)"'
        exit 1
    fi

    # The guard. Zero checks is indistinguishable from not-yet-started, so wait
    # out a grace period first -- then refuse rather than merge on nothing.
    if [ "${total:-0}" -eq 0 ] && [ "$elapsed" -ge "$GRACE" ]; then
        if [ "$REFIRE" -eq 1 ] && [ "$refired" -eq 0 ]; then
            say "no checks after ${elapsed}s -- closing and reopening to re-fire the event"
            gh pr close "$PR" ${GH_ARGS[@]+"${GH_ARGS[@]}"} >/dev/null 2>&1
            sleep 5
            gh pr reopen "$PR" ${GH_ARGS[@]+"${GH_ARGS[@]}"} >/dev/null 2>&1
            refired=1; started=$(date +%s)
            sleep 20; continue
        fi
        say "NOT MERGING -- no checks exist for this pull request after ${elapsed}s."
        say ""
        say "  GitHub created no check suite for the head commit, so there is"
        say "  nothing to be green. Merging now would merge something untested."
        say ""
        say "  Re-fire the event:  gh pr close $PR && gh pr reopen $PR"
        say "  Or re-run with --refire to do that automatically."
        say "  Permanent fix: require the build check on this branch (#55)."
        exit 1
    fi

    if [ "${total:-0}" -gt 0 ] && [ "${pending:-0}" -eq 0 ]; then
        say "green (${total} check(s)) -- merging"
        gh pr merge "$PR" ${GH_ARGS[@]+"${GH_ARGS[@]}"} --squash --delete-branch || exit 1
        say "merged"
        exit 0
    fi

    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        say "NOT MERGING -- timed out after ${elapsed}s with ${pending} check(s) still pending."
        exit 1
    fi
    sleep 20
done
