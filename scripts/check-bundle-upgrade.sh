#!/usr/bin/env bash
# An older bundled install moves to the PsyNeuView this app carries (#186).
#
# App updates used to bring a new PsyNeuView that was never used: launch
# started whatever folder setup had saved, so every bundled user stayed on the
# version they first installed. This reproduces that user's state and requires
# the app to move by itself.
#
# Run after a first launch has set the app up (scripts/measure-boot.sh does,
# unattended): that saved `repoPath` is the current version's folder. This
# copies it to an "older" folder stamped 0.0.1, points the saved setting there,
# launches again, and requires the app to have moved back to the current
# folder and come up healthy.
set -euo pipefail

DOMAIN="com.psyneuview.macapp"
current="$(defaults read "$DOMAIN" repoPath)"
[ -d "$current" ] || { echo "no current install at '$current' — run measure-boot first" >&2; exit 2; }
want="$(sed -n 's/^version=//p' "$current/BUNDLED_VERSION")"

old="$(dirname "$current")/psyneuview-0.0.1-upgrade-check"
cleanup() {
  # Leave the app set up as it was found, whatever happened.
  defaults write "$DOMAIN" repoPath "$current"
  rm -rf "$old"
}
trap cleanup EXIT

rm -rf "$old"
cp -Rc "$current" "$old" 2>/dev/null || cp -R "$current" "$old"
printf 'version=0.0.1\nref=upgrade-check\n' > "$old/BUNDLED_VERSION"
defaults write "$DOMAIN" repoPath "$old"
echo "Planted an older install (0.0.1) at $old; the app carries $want."

./scripts/measure-boot.sh "${1:-0.25}"

now="$(defaults read "$DOMAIN" repoPath)"
if [ "$now" != "$current" ]; then
  echo "upgrade: still on $now — the app did not move to PsyNeuView $want" >&2
  exit 1
fi
echo "upgrade: moved from 0.0.1 to $want by itself, and started."
