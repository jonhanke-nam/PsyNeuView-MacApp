#!/bin/bash
#
# Notarize and staple the PsyNeuView DMG.
#
# Usage: ./scripts/notarize-dmg.sh
# Prerequisites:
#   - DMG must already be built (run 'make dmg' or create-dmg.sh first)
#   - App inside must be code signed (run 'make sign' first)
#   - Notarization credentials stored in Keychain:
#     xcrun notarytool store-credentials "PsyNeuView" --apple-id "..." --team-id "..."
#
set -euo pipefail

# Credentials profile name (stored in Keychain via notarytool store-credentials)
CREDENTIALS_PROFILE="PsyNeuView"

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "0.1.0")
DMG_NAME="PsyNeuView-${VERSION}.dmg"

if [ ! -f "${DMG_NAME}" ]; then
    echo "Error: ${DMG_NAME} not found. Run 'make dmg' first."
    exit 1
fi

echo "Notarizing ${DMG_NAME}..."

# CI passes credentials directly via env vars (no Keychain on the runner);
# locally we fall through to the stored Keychain profile.
if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    xcrun notarytool submit "${DMG_NAME}" \
        --apple-id "${NOTARY_APPLE_ID}" \
        --team-id "${NOTARY_TEAM_ID}" \
        --password "${NOTARY_PASSWORD}" \
        --wait
else
    xcrun notarytool submit "${DMG_NAME}" \
        --keychain-profile "${CREDENTIALS_PROFILE}" \
        --wait
fi

echo ""
echo "Stapling notarization ticket..."
xcrun stapler staple "${DMG_NAME}"

echo ""
echo "Verifying..."
spctl --assess --type open --context context:primary-signature --verbose "${DMG_NAME}" 2>&1 || true

echo ""
echo "  ✓ ${DMG_NAME} notarized and stapled"
