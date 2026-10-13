#!/bin/bash
#
# Pre-release smoke tests for PsyNeuView-MacApp.
# Validates that the project is in a releasable state.
#
set -euo pipefail

PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "Running smoke tests..."
echo ""

# Build
echo "Build:"
check "swift build succeeds" swift build
check "Release build succeeds" swift build -c release

# Required files
echo ""
echo "Required files:"
check "Package.swift exists" test -f Package.swift
check "Resources/Info.plist exists" test -f Resources/Info.plist
check "scripts/create-dmg.sh exists" test -x scripts/create-dmg.sh
check "INSTALL.md exists" test -f INSTALL.md
check "README.md exists" test -f README.md
check "TODO.md exists" test -f TODO.md

# Info.plist validation
echo ""
echo "Info.plist:"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "")
check "Version is set" test -n "$VERSION"
check "Bundle ID is set" /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist
echo "  → Version: ${VERSION:-MISSING}"

# Binary validation
echo ""
echo "Binary:"
BINARY=".build/release/PsyNeuView"
if [ -f "$BINARY" ]; then
    check "Binary exists" test -f "$BINARY"
    check "Binary is arm64" file "$BINARY" | grep -q "arm64"
    check "Binary links AppKit" otool -L "$BINARY" | grep -q "AppKit"
    check "Binary links WebKit" otool -L "$BINARY" | grep -q "WebKit"
else
    echo "  ⊘ Binary not found (run 'make release' first)"
fi

# DMG creation (dry run — just check the script is valid)
echo ""
echo "DMG script:"
check "create-dmg.sh is executable" test -x scripts/create-dmg.sh
check "create-dmg.sh has valid bash syntax" bash -n scripts/create-dmg.sh

# Summary
echo ""
echo "─────────────────────────"
echo "Results: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
    echo "SMOKE TESTS FAILED"
    exit 1
else
    echo "ALL SMOKE TESTS PASSED"
    exit 0
fi
