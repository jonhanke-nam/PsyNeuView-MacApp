#!/bin/bash
#
# Checks if the latest DMG release is up-to-date with the working branch.
#
# jonhanke-devel, not main: main is dormant for this repo, so counting
# against it reported "up to date" while ten commits sat unreleased.
# Run this anytime, or add to your workflow as a reminder.
#
# Usage: ./scripts/check-release-freshness.sh
#
set -euo pipefail

REPO="jonhanke-nam/PsyNeuView-MacApp"
# Overridable, so this still works from a fork or a differently-named trunk.
BRANCH="${RELEASE_BRANCH:-jonhanke-devel}"

echo "Checking release freshness..."

# Get latest release tag
LATEST_TAG=$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || echo "none")
echo "  Latest release: $LATEST_TAG"

if [ "$LATEST_TAG" = "none" ]; then
    echo "  ⚠ No releases found. Run: make github-release"
    exit 1
fi

# Check if the working branch has commits beyond the latest tag
COMMITS_AHEAD=$(git rev-list --count "$LATEST_TAG..$BRANCH" 2>/dev/null || echo "?")
echo "  Commits on $BRANCH since $LATEST_TAG: $COMMITS_AHEAD"

if [ "$COMMITS_AHEAD" = "0" ]; then
    echo "  ✓ DMG is up to date"
    exit 0
else
    echo ""
    echo "  ⚠ DMG is $COMMITS_AHEAD commit(s) behind $BRANCH!"
    echo ""
    echo "  Recent changes not in the release:"
    git log --oneline "$LATEST_TAG..$BRANCH" 2>/dev/null | head -10
    echo ""
    echo "  To update the DMG:"
    echo "    git checkout $BRANCH"
    echo "    make github-release"
    echo "    git checkout jonhanke-dev"
    exit 1
fi
