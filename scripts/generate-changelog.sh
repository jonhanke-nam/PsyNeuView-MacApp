#!/usr/bin/env bash
# Regenerate the public CHANGELOG.md from the published releases.
#
# The releases page is the record: its notes come from each annotated tag
# message, which is the single source (see docs/release-notes.md). This mirrors
# that page into one file you can read end to end, grep, and open offline --
# the things the paginated web view cannot do.
#
# Derived, never hand-edited. Regenerating is always safe; editing is not,
# because the next run overwrites it. That is the point: a hand-maintained
# changelog is a second thing to keep true, and ours drifted twelve releases
# before anyone noticed (#161).
#
# Usage: ./scripts/generate-changelog.sh [output-path]
set -euo pipefail

REPO="${CHANGELOG_REPO:-jonhanke-nam/PsyNeuView-releases}"
OUT="${1:-../PsyNeuView-releases/CHANGELOG.md}"

command -v gh >/dev/null || { echo "error: gh is required" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
    echo "# Changelog"
    echo
    echo "Every released version of the PsyNeuView Mac app, newest first."
    echo
    echo "Generated from the published releases by \`scripts/generate-changelog.sh\`"
    echo "in the PsyNeuView-MacApp repository. Do not edit by hand -- the next"
    echo "release overwrites it. Release notes are written as the annotated tag"
    echo "message when a version is cut."
    echo
    echo "Downloads for every version: https://github.com/${REPO}/releases"
    echo
} > "$TMP"

# Newest first. `gh release list` already sorts that way; we re-sort by version
# so a hand-made release out of chronological order still lands correctly.
TAGS="$(gh release list --repo "$REPO" --limit 200 --json tagName --jq '.[].tagName' | sort -Vr)"

[ -n "$TAGS" ] || { echo "error: no releases found in $REPO" >&2; exit 1; }

COUNT=0
while read -r tag; do
    [ -n "$tag" ] || continue
    meta="$(gh release view "$tag" --repo "$REPO" --json name,body,publishedAt \
            --jq '[.name, (.publishedAt | split("T")[0]), .body] | @tsv')" || continue
    name="$(printf '%s' "$meta" | cut -f1)"
    date="$(printf '%s' "$meta" | cut -f2)"
    # @tsv escapes newlines as \n; restore them.
    body="$(printf '%s' "$meta" | cut -f3- | perl -pe 's/\\n/\n/g; s/\\t/\t/g; s/\\\\/\\/g')"

    {
        # The title usually contains an em dash already, so the date goes on
        # its own line rather than after a second one.
        echo "## ${name:-$tag}"
        echo
        echo "_Released ${date} · [\`${tag}\`](https://github.com/${REPO}/releases/tag/${tag})_"
        echo
        printf '%s\n' "$body"
        echo
    } >> "$TMP"
    COUNT=$((COUNT + 1))
done <<< "$TAGS"

mkdir -p "$(dirname "$OUT")"
mv "$TMP" "$OUT"
trap - EXIT
echo "wrote $OUT ($COUNT releases)"
