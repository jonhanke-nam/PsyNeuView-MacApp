#!/bin/bash
#
# Notarize and staple the PsyNeuView .app itself (before it's wrapped in a DMG),
# so the app carries its own notarization ticket. The DMG is notarized+stapled
# separately by notarize-dmg.sh; stapling the app too makes offline first-launch
# robust (Gatekeeper doesn't need an online check). See #31.
#
# Usage: ./scripts/notarize-app.sh
# Prerequisites:
#   - App built + signed (run 'make sign' first)
#   - Notarization credentials in the Keychain profile "PsyNeuView", or the
#     NOTARY_* env vars (CI) — same as notarize-dmg.sh.
#
set -euo pipefail

# Built into .build so a stale bundle cannot appear in Launchpad beside a
# real install — Spotlight skips dot-directories but indexes any .app
# elsewhere (#118). Overridable so a caller can sign an arbitrary bundle.
APP_PATH="${APP_PATH:-.build/PsyNeuView.app}"
CREDENTIALS_PROFILE="PsyNeuView"
ZIP_PATH="PsyNeuView-app-notarize.zip"

if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found. Run 'make sign' first."
    exit 1
fi

echo "Notarizing ${APP_PATH}..."

# notarytool can't submit a .app directly — it needs a zip/pkg/dmg container.
# ditto --keepParent preserves the .app wrapper inside the archive.
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
trap 'rm -f "${ZIP_PATH}"' EXIT

# CI passes credentials via env vars (no Keychain on the runner); locally we
# fall through to the stored Keychain profile. Mirrors notarize-dmg.sh.
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    xcrun notarytool submit "${ZIP_PATH}" \
        --apple-id "${NOTARY_APPLE_ID}" \
        --team-id "${NOTARY_TEAM_ID}" \
        --password "${NOTARY_PASSWORD}" \
        --wait
else
    xcrun notarytool submit "${ZIP_PATH}" \
        --keychain-profile "${CREDENTIALS_PROFILE}" \
        --wait
fi

echo ""
echo "Stapling notarization ticket to the app..."
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo ""
echo "  ✓ ${APP_PATH} notarized and stapled"
