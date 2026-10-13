#!/bin/bash
#
# Create a GitHub release with the DMG attached.
#
# Usage: ./scripts/release.sh [version]
#   version: optional, defaults to version in Info.plist
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - git remote 'origin' configured
#   - All changes committed
#
set -euo pipefail

REPO_OWNER="jonhanke-nam"
REPO_NAME="PsyNeuView-MacApp"

# Read version
if [ -n "${1:-}" ]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
fi
TAG="v${VERSION}"
DMG_NAME="PsyNeuView-${VERSION}.dmg"

echo "=== PsyNeuView Release ${TAG} ==="
echo ""

# Pre-flight checks
echo "1. Pre-flight checks..."

if ! command -v gh &> /dev/null; then
    echo "   Error: gh CLI not found. Install with: brew install gh"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "   Error: gh not authenticated. Run: gh auth login"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "   Error: Uncommitted changes. Commit or stash before releasing."
    exit 1
fi

# Ensure we're releasing from main
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "   Error: Releases must be cut from 'main' branch (currently on '$CURRENT_BRANCH')."
    echo "   Run: git checkout main && git merge jonhanke-dev && git push"
    exit 1
fi

echo "   ✓ All checks passed"

# Run smoke tests
echo ""
echo "2. Running smoke tests..."
make smoke-test

# The same gates the release workflow runs (#174): the app's tests, and the
# bundled PsyNeuView having passed its full checks on devel.
echo ""
echo "2b. Running the app's tests..."
swift test
echo ""
echo "2c. Checking the bundled PsyNeuView passed its full checks..."
./scripts/check-psyneuview-tested.sh

# Build signed DMG
echo ""
echo "3. Building and signing..."
make sign
# Launch the signed app and wait for it to finish booting (#174).
./scripts/measure-boot.sh 0.25
make dmg

if [ ! -f "$DMG_NAME" ]; then
    echo "   Error: ${DMG_NAME} not found after build"
    exit 1
fi

# Notarize if credentials are available.
# Probe the actual profile with `notarytool history` rather than guessing the
# Keychain service name: store-credentials saves under
# `com.apple.gke.notary.tool.saved-creds` (account = profile name), which the
# old `find-generic-password -s com.apple.gke.notary.tool` check never matched —
# so notarization was silently skipped even with valid creds (#18). `history`
# makes a real API call, verifying the profile both exists and authenticates.
echo ""
echo "4. Notarizing..."
if xcrun notarytool history --keychain-profile "PsyNeuView" &>/dev/null 2>&1; then
    ./scripts/notarize-dmg.sh
else
    echo "   ⚠ Notarization credentials not found or not usable. Skipping."
    echo "   To enable: xcrun notarytool store-credentials \"PsyNeuView\" --apple-id ... --team-id ..."
fi

# Update Sparkle appcast
echo ""
echo "5. Updating Sparkle appcast..."
if [ -f ".build/artifacts/sparkle/Sparkle/bin/sign_update" ]; then
    ./scripts/update-appcast.sh
else
    echo "   ⚠ Sparkle tools not found. Skipping appcast update."
    echo "   Run 'swift build' first to download Sparkle."
fi

# Ensure remote exists and push
echo ""
echo "6. Setting up GitHub remote..."
if ! git remote get-url origin &> /dev/null; then
    echo "   Creating GitHub repo..."
    gh repo create "${REPO_OWNER}/${REPO_NAME}" --private --source=. --push
    # Switch to SSH for reliable auth
    git remote set-url origin "git@github.com:${REPO_OWNER}/${REPO_NAME}.git"
else
    echo "   ✓ Remote already configured"
    git push origin "$(git branch --show-current)" 2>/dev/null || git push -u origin "$(git branch --show-current)"
fi

# Create and push tag
echo "   Tagging ${TAG}..."
git tag -f "$TAG"
git push origin "$TAG" --force 2>/dev/null

# Create release
echo ""
echo "7. Creating GitHub Release ${TAG}..."

# Check if release already exists
if gh release view "$TAG" --repo "${REPO_OWNER}/${REPO_NAME}" &> /dev/null; then
    echo "   Release ${TAG} already exists. Updating..."
    gh release upload "$TAG" "$DMG_NAME" --clobber --repo "${REPO_OWNER}/${REPO_NAME}"
else
    gh release create "$TAG" "$DMG_NAME" \
        --repo "${REPO_OWNER}/${REPO_NAME}" \
        --title "PsyNeuView ${VERSION}" \
        --notes "$(cat <<NOTES
## PsyNeuView ${VERSION}

### Install

1. Download \`${DMG_NAME}\` below
2. Open the DMG and drag PsyNeuView to Applications
3. See [INSTALL.md](https://github.com/${REPO_OWNER}/${REPO_NAME}/blob/main/INSTALL.md) for detailed instructions

### Requirements

- macOS 14 (Sonoma) or later
- Python 3.9+
- Node.js 18+
- SSH key configured for GitHub
NOTES
)"
fi

# Print results
echo ""
echo "=== Release Complete ==="
echo ""
RELEASE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${TAG}"
INSTALL_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/blob/main/INSTALL.md"
echo "Release:  ${RELEASE_URL}"
echo "Install:  ${INSTALL_URL}"
echo "DMG:      ${DMG_NAME} ($(du -h "$DMG_NAME" | cut -f1))"
echo ""
echo "Share this with new users:"
echo "  ${INSTALL_URL}"
