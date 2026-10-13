#!/bin/bash
#
# Creates a distributable DMG for PsyNeuView.
# Uses only built-in macOS tools (hdiutil).
#
# Usage: ./scripts/create-dmg.sh
# Prerequisites: PsyNeuView.app must already be built (run 'make app' first)
#
set -euo pipefail

APP_NAME="PsyNeuView"
# Built into .build so a stale bundle cannot appear in Launchpad beside a
# real install — Spotlight skips dot-directories but indexes any .app
# elsewhere (#118). Overridable so a caller can sign an arbitrary bundle.
APP_PATH="${APP_PATH:-.build/PsyNeuView.app}"

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "0.1.0")

DMG_NAME="${APP_NAME}-${VERSION}"
DMG_FINAL="${DMG_NAME}.dmg"
STAGING_DIR=".dmg-staging"

echo "Creating ${DMG_FINAL}..."

# Verify the .app exists
if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found. Run 'make app' first."
    exit 1
fi

# Clean up any previous artifacts
rm -rf "${STAGING_DIR}" "${DMG_FINAL}"

# Create staging directory with app and Applications symlink
echo "  Staging files..."
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

# Create compressed DMG directly from the staging directory
echo "  Creating compressed disk image..."
hdiutil create \
    -srcfolder "${STAGING_DIR}" \
    -volname "${APP_NAME}" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    "${DMG_FINAL}" \
    -quiet

# Clean up
rm -rf "${STAGING_DIR}"

# Report
DMG_SIZE=$(du -h "${DMG_FINAL}" | cut -f1)
echo ""
echo "Created ${DMG_FINAL} (${DMG_SIZE})"
echo ""
echo "To distribute:"
echo "  1. Share the DMG file"
echo "  2. User opens it, drags PsyNeuView to Applications"
echo "  3. User launches PsyNeuView — setup wizard handles the rest"
