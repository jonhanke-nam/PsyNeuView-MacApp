#!/usr/bin/env bash
# Collect the raw material for release notes from a commit range.
# Prints every merged PR with its linked issue title, so notes are written
# from what shipped rather than from memory.
#
# Usage: draft-notes.sh <prev-tag> <new-tag-or-HEAD> [repo-dir]
set -euo pipefail
PREV="${1:?usage: draft-notes.sh <prev-tag> <new-tag|HEAD> [repo-dir]}"
NEW="${2:?}"
DIR="${3:-.}"
cd "$DIR"

printf '%s..%s — %s commits, %s merged PRs\n\n' "$PREV" "$NEW" \
  "$(git rev-list --count "$PREV..$NEW")" \
  "$(git log "$PREV..$NEW" --merges --oneline | wc -l | tr -d ' ')"

git log "$PREV..$NEW" --merges --format='%s' \
| sed -nE 's/.*#([0-9]+) from [^/]+\/(.*)/\1 \2/p' \
| while read -r pr branch; do
    iss=$(printf '%s' "$branch" | grep -oE '[0-9]{3,4}$' || true)
    if [ -n "$iss" ]; then
        meta=$(gh issue view "$iss" --json title,labels \
               --jq '.title + "\t" + ([.labels[].name] | join(","))' 2>/dev/null || true)
    fi
    if [ -n "${meta:-}" ]; then
        title=${meta%%$'\t'*}; labels=${meta#*$'\t'}
        printf 'PR #%-5s issue #%-5s %s\n' "$pr" "$iss" "$title"
        [ -n "$labels" ] && printf '                        labels: %s\n' "$labels"
    else
        printf 'PR #%-5s %-12s %s\n' "$pr" "(no issue)" "$branch"
    fi
    meta=""
done
