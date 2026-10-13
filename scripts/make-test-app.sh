#!/bin/bash
#
# Turn the built PsyNeuView.app into "PsyNeuView Test.app" (#209).
#
#     scripts/make-test-app.sh [source.app] [destination.app]
#
# Defaults: .build/PsyNeuView.app -> ".build/PsyNeuView Test.app". The binary,
# the bundled Python, PsyNeuView archive and uv are the same files; what
# changes is the identity, which is the bundle id and nothing else. The app
# derives everything from it at run time (AppIdentity): its name, its
# Application Support and Logs folders, its preferences domain, the backend's
# settings file and clone folders, and that Sparkle never runs.
#
# So the Info.plist is rewritten:
#   - CFBundleIdentifier        com.psyneuview.macapp.test
#   - CFBundleName/DisplayName  PsyNeuView Test
#   - SUFeedURL, SUPublicEDKey  removed; SUEnableAutomaticChecks off
# and the icon gets a TEST ribbon (scripts/make-test-icon.sh). The build
# commit is stamped into both apps by the Makefile.
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="${1:-.build/PsyNeuView.app}"
DEST="${2:-.build/PsyNeuView Test.app}"
BUNDLE_ID="com.psyneuview.macapp.test"
NAME="PsyNeuView Test"

[ -d "${SOURCE}" ] || { echo "Error: ${SOURCE} not found. Run 'make app' first." >&2; exit 1; }

PLIST="${DEST}/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy

echo "Assembling ${DEST}..."
rm -rf "${DEST}"
cp -R "${SOURCE}" "${DEST}"

"${PB}" -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${PLIST}"
"${PB}" -c "Set :CFBundleName ${NAME}" "${PLIST}"
"${PB}" -c "Set :CFBundleDisplayName ${NAME}" "${PLIST}"
# No updates: no feed to check, no key to verify against, no automatic check.
"${PB}" -c "Delete :SUFeedURL" "${PLIST}" 2>/dev/null || true
"${PB}" -c "Delete :SUPublicEDKey" "${PLIST}" 2>/dev/null || true
"${PB}" -c "Set :SUEnableAutomaticChecks false" "${PLIST}" 2>/dev/null \
    || "${PB}" -c "Add :SUEnableAutomaticChecks bool false" "${PLIST}"

./scripts/make-test-icon.sh Resources/AppIcon.icns "${DEST}/Contents/Resources/AppIcon.icns"

# LaunchServices caches the icon by bundle path; a fresh bundle has no cache.
# Touching the bundle makes Finder notice the new Info.plist either way.
touch "${DEST}"

echo "  bundle id: $("${PB}" -c 'Print :CFBundleIdentifier' "${PLIST}")"
echo "  name:      $("${PB}" -c 'Print :CFBundleName' "${PLIST}")"
echo "  version:   $("${PB}" -c 'Print :CFBundleShortVersionString' "${PLIST}")"
echo "  commit:    $("${PB}" -c 'Print :PNVBuildCommit' "${PLIST}" 2>/dev/null || echo '(not stamped)')"
echo "Built ${DEST} — open it with: open \"${DEST}\""
echo "It runs beside the real app, with its own settings, folders and logs."
