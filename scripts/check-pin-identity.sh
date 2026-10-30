#!/bin/bash
#
# The bundled PsyNeuView's version must name exactly the tag it was built from.
#
# PSYNEUVIEW_VERSION names the folder a bundled install unpacks into, and an
# app update moves to the PsyNeuView it carries only when that version differs
# from the one in use (BundledUpgrade). Release candidates 0.6.7-rc1 to rc3
# each bundled a different tag (v0.6.9-rc1, -rc2, -rc3) but all called it
# "0.6.9", so an app updated from rc1 kept running rc1's PsyNeuView while
# About said rc3. Tags are unique, so a version that spells out its tag is too:
# v0.6.9-rc3 must be "0.6.9-rc3", and the final v0.6.9 "0.6.9".
#
# Usage: scripts/check-pin-identity.sh              check psyneuview-pin.conf
#        scripts/check-pin-identity.sh <ref> <ver>  check a given pair
#        scripts/check-pin-identity.sh --self-test
set -euo pipefail

cd "$(dirname "$0")/.."

# Prints nothing and succeeds when the pair agrees; prints why otherwise.
mismatch() {
  local ref="$1" version="$2"
  [ "${ref#v}" = "$version" ] && return 1
  echo "PSYNEUVIEW_VERSION is '${version}' but PSYNEUVIEW_REF is '${ref}': the version must be the tag without its 'v' ('${ref#v}'), or an app update can keep running the PsyNeuView it already has."
}

if [ "${1:-}" = "--self-test" ]; then
  failed=0
  expect() {  # expect ok|bad ref version
    local got=ok
    mismatch "$2" "$3" >/dev/null && got=bad
    if [ "$got" != "$1" ]; then echo "✗ $2 / $3: expected $1, got $got"; failed=1; fi
  }
  expect ok  v0.6.9      0.6.9
  expect ok  v0.6.9-rc3  0.6.9-rc3
  expect bad v0.6.9-rc3  0.6.9       # the 0.6.7-rc3 bug
  expect bad v0.6.9      0.6.9-rc3
  expect bad v0.6.9-rc2  0.6.9-rc3
  [ "$failed" = 0 ] && echo "✓ check-pin-identity self-test passed"
  exit "$failed"
fi

if [ $# -eq 2 ]; then
  REF="$1"; VERSION="$2"
else
  # shellcheck source=psyneuview-pin.conf
  source scripts/psyneuview-pin.conf
  REF="${PSYNEUVIEW_REF}"; VERSION="${PSYNEUVIEW_VERSION}"
fi

if why="$(mismatch "$REF" "$VERSION")"; then
  echo "::error::${why}" >&2
  echo "✗ ${why}" >&2
  exit 1
fi
echo "✓ bundled PsyNeuView ${VERSION} names its tag ${REF}"
