#!/bin/bash
#
# Make the test app's icon from the real one: the same picture with a TEST
# ribbon across the corner (#209).
#
#     scripts/make-test-icon.sh [source.icns] [output.icns]
#
# Defaults: Resources/AppIcon.icns -> .build/AppIcon-Test.icns. Generated at
# build time rather than committed, so the two icons cannot drift apart when
# the real one changes. Uses only what a build machine has: iconutil to take
# the .icns apart and put it back, and a Swift script (AppKit) to draw.
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="${1:-Resources/AppIcon.icns}"
OUTPUT="${2:-.build/AppIcon-Test.icns}"

[ -f "${SOURCE}" ] || { echo "Error: ${SOURCE} not found" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "Error: iconutil is required" >&2; exit 1; }
command -v swift >/dev/null || { echo "Error: swift is required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ICONSET="${TMP}/AppIcon.iconset"
iconutil -c iconset "${SOURCE}" -o "${ICONSET}"
swift scripts/test-icon-ribbon.swift "${ICONSET}" TEST
mkdir -p "$(dirname "${OUTPUT}")"
iconutil -c icns "${ICONSET}" -o "${OUTPUT}"
echo "  ✓ wrote ${OUTPUT}"
