#!/bin/bash
#
# Update the Sparkle appcast with a new release entry.
#
# The appcast lives in the public PsyNeuView-releases repo (served via GitHub Pages).
# This script clones that repo, adds a new entry, and pushes.
#
# Usage: ./scripts/update-appcast.sh
# Prerequisites:
#   - DMG must already be built and signed
#   - Sparkle EdDSA key in Keychain (generated via generate_keys)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_OWNER="jonhanke-nam"
MACAPP_REPO="PsyNeuView-MacApp"
RELEASES_REPO="PsyNeuView-releases"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "0.1.0")
DMG_NAME="PsyNeuView-${VERSION}.dmg"
TAG="v${VERSION}"

if [ ! -f "${DMG_NAME}" ]; then
    echo "Error: ${DMG_NAME} not found. Build the DMG first."
    exit 1
fi

# Build Sparkle tools if needed
if [ ! -f "${SIGN_UPDATE}" ]; then
    echo "Building Sparkle tools..."
    swift build 2>/dev/null
fi

if [ ! -f "${SIGN_UPDATE}" ]; then
    echo "Error: sign_update not found at ${SIGN_UPDATE}"
    exit 1
fi

echo "Signing ${DMG_NAME} for Sparkle..."

# CI provides the EdDSA private key as a file (no Keychain on the runner).
# Locally, sign_update reads the key from the user's Keychain.
SIGN_UPDATE_ARGS=()
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    SIGN_UPDATE_ARGS+=(-f "${SPARKLE_PRIVATE_KEY_FILE}")
fi

# Get EdDSA signature and file length
SIGNATURE=$("${SIGN_UPDATE}" "${SIGN_UPDATE_ARGS[@]}" "${DMG_NAME}" 2>&1 | grep "sparkle:edSignature" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
LENGTH=$(stat -f%z "${DMG_NAME}")
PUB_DATE=$(date -R)
# Sparkle downloads enclosures anonymously. The MacApp code repo is private, so
# its release assets 404 for anyone without access — auto-update could detect a
# new version but never download it (#52). Host the DMG in the PUBLIC releases
# repo (the same repo that serves this appcast) and point the enclosure there.
DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${RELEASES_REPO}/releases/download/${TAG}/${DMG_NAME}"

if [ -z "${SIGNATURE}" ]; then
    echo "Error: Failed to generate EdDSA signature. Is the signing key in your Keychain?"
    echo "Run: .build/artifacts/sparkle/Sparkle/bin/generate_keys"
    exit 1
fi

echo "  Signature: ${SIGNATURE}"
echo "  Length: ${LENGTH}"

# Publish the notarized DMG as a PUBLIC release asset in the releases repo so the
# enclosure URL above actually resolves for anonymous Sparkle downloads (#52).
# In CI, RELEASES_REPO_TOKEN authenticates to the releases repo; locally we fall
# through to the user's ambient `gh` auth (which owns both repos).
[ -n "${RELEASES_REPO_TOKEN:-}" ] && export GH_TOKEN="${RELEASES_REPO_TOKEN}"

# Resolve the notes BEFORE publishing anything.
#
# This used to be `--notes-file <(tag-notes.sh ...)`. A process substitution
# that fails does not fail the command it feeds, and `set -e` does not see it,
# so when tag-notes.sh refused 0.5.6 the release was still created — published,
# with the DMG attached, and completely empty notes. Failing after the side
# effect is worse than failing before it.
NOTES_FILE=$(mktemp)
trap 'rm -f "${NOTES_FILE}"' EXIT
"${SCRIPT_DIR}/tag-notes.sh" "${TAG}" > "${NOTES_FILE}"

echo "  Publishing ${DMG_NAME} to public ${RELEASES_REPO}..."
if gh release view "${TAG}" --repo "${REPO_OWNER}/${RELEASES_REPO}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${DMG_NAME}" --clobber --repo "${REPO_OWNER}/${RELEASES_REPO}"
    # Re-apply the notes and title too, so re-running after a failure repairs a
    # release rather than leaving whatever the broken run left behind.
    gh release edit "${TAG}" \
        --repo "${REPO_OWNER}/${RELEASES_REPO}" \
        --title "PsyNeuView ${VERSION}" \
        --notes-file "${NOTES_FILE}"
else
    gh release create "${TAG}" "${DMG_NAME}" \
        --repo "${REPO_OWNER}/${RELEASES_REPO}" \
        --title "PsyNeuView ${VERSION}" \
        --notes-file "${NOTES_FILE}"
fi

# Clone the releases repo into a temp directory.
# CI overrides RELEASES_REPO_URL to push via HTTPS+token (no SSH on the runner).
RELEASES_REPO_URL="${RELEASES_REPO_URL:-git@github.com:${REPO_OWNER}/${RELEASES_REPO}.git}"
TEMP_DIR=$(mktemp -d)
echo "  Cloning ${RELEASES_REPO}..."
git clone --quiet "${RELEASES_REPO_URL}" "${TEMP_DIR}"

APPCAST="${TEMP_DIR}/docs/appcast.xml"

if [ ! -f "${APPCAST}" ]; then
    echo "Error: appcast.xml not found in ${RELEASES_REPO}"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Sparkle shows this in the update dialog. Without it the dialog offers a version
# number and no reason to install it.
RELEASE_HTML="$("${SCRIPT_DIR}/tag-notes.sh" "${TAG}" --html)"

# Build the new <item> XML
ITEM="        <item>
            <title>Version ${VERSION}</title>
            <description><![CDATA[
${RELEASE_HTML}
            ]]></description>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url=\"${DOWNLOAD_URL}\"
                       length=\"${LENGTH}\"
                       type=\"application/octet-stream\"
                       sparkle:edSignature=\"${SIGNATURE}\" />
        </item>"

# Insert the new item after the comment marker in the appcast.
# Use sed's `r` command (read-from-file) instead of `awk -v`, since
# `awk -v` cannot accept multi-line strings (POSIX limitation — fails
# with "awk: newline in string"). See #16.
if grep -q "<!-- New releases" "${APPCAST}"; then
    TEMP_FILE=$(mktemp)
    ITEM_FILE=$(mktemp)
    printf '%s\n' "${ITEM}" > "${ITEM_FILE}"
    sed "/<!-- New releases/r ${ITEM_FILE}" "${APPCAST}" > "${TEMP_FILE}"
    rm -f "${ITEM_FILE}"
    mv "${TEMP_FILE}" "${APPCAST}"
else
    echo "Error: Could not find insertion marker in appcast.xml"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Commit and push
cd "${TEMP_DIR}"
git add docs/appcast.xml
git commit -m "Add PsyNeuView v${VERSION} to appcast

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push origin main

# Clean up
cd -
rm -rf "${TEMP_DIR}"

echo ""
echo "  ✓ Appcast updated with v${VERSION}"
echo "  Live at: https://${REPO_OWNER}.github.io/${RELEASES_REPO}/appcast.xml"
