#!/bin/bash
#
# Code sign PsyNeuView.app with Developer ID certificate.
#
# Usage: ./scripts/sign-app.sh
# Prerequisites: PsyNeuView.app must already be built (run 'make app' first)
#                Developer ID Application certificate in Keychain
#
set -euo pipefail

# Built into .build so a stale bundle cannot appear in Launchpad beside a
# real install — Spotlight skips dot-directories but indexes any .app
# elsewhere (#118). Overridable so a caller can sign an arbitrary bundle.
APP_PATH="${APP_PATH:-.build/PsyNeuView.app}"
ENTITLEMENTS="Resources/entitlements.plist"

# Find the Developer ID signing identity from the Keychain
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')

if [ -z "$IDENTITY" ]; then
    echo "Error: No 'Developer ID Application' certificate found in Keychain."
    echo "Import your .p12 certificate first:"
    echo "  security import Certificates.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign"
    exit 1
fi

echo "Signing ${APP_PATH} with: ${IDENTITY}"

# Verify the .app exists
if [ ! -d "${APP_PATH}" ]; then
    echo "Error: ${APP_PATH} not found. Run 'make app' first."
    exit 1
fi

# Sign a target with the hardened runtime + a SECURE TIMESTAMP, then verify the
# timestamp actually landed — retrying with backoff if it didn't.
#
# Apple's timestamp server (timestamp.apple.com) throttles rapid bursts, so on
# CI some nested signs would come back without a secure timestamp. The previous
# version signed nested code inside `[ -e ] && { ... }`, which made the codesign
# call the RHS of `&&` and therefore NON-FATAL under `set -e` — so those
# failures were silently swallowed and un-timestamped binaries shipped, failing
# notarization (#37). Here every sign is a checked, fatal call, and we confirm a
# `Timestamp=` is present before moving on.
#
# Usage: sign_ts <codesign-args...> <target>   (target must be the last arg)
sign_ts() {
    local target="${@: -1}"   # last positional arg (the thing being signed)
    local attempt backoff
    for attempt in $(seq 1 8); do
        if codesign --force --options runtime --timestamp --sign "${IDENTITY}" "$@" 2>&1 \
            && codesign -dvv "${target}" 2>&1 | grep -q "Timestamp="; then
            return 0
        fi
        backoff=$((attempt * 15)); [ "${backoff}" -gt 60 ] && backoff=60
        echo "  ⚠ no secure timestamp on ${target} yet (attempt ${attempt}/8); backing off ${backoff}s..."
        sleep "${backoff}"
    done
    echo "Error: could not obtain a secure timestamp for ${target} after 8 attempts (Apple timestamp service throttling?)" >&2
    return 1
}

# Sign nested code inside-out. `codesign --deep` is unreliable for nested
# BUNDLES (helper apps / XPC services) — sign each explicitly, deepest first,
# before the framework and then the outer app.
SPARKLE="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE}" ]; then
    V="${SPARKLE}/Versions/B"
    for item in \
        "${V}/XPCServices/Downloader.xpc" \
        "${V}/XPCServices/Installer.xpc" \
        "${V}/Updater.app" \
        "${V}/Autoupdate" \
        "${SPARKLE}"; do
        if [ -e "${item}" ]; then
            echo "  signing $(basename "${item}")"
            sign_ts "${item}"
        fi
    done
fi

# Sign the bundled CPython runtime. (#64)
#
# python-build-standalone ships these adhoc/linker-signed; re-signing with the
# Developer ID is what notarization requires. Only ~10 Mach-O files: the
# interpreter, a handful of dylibs, and two extension modules that aren't
# statically linked into libpython.
#
# The INTERPRETER gets the entitlements, not just the outer app. Entitlements are
# per-binary and are not inherited from the parent process, and it is the
# interpreter that dlopens unsigned numpy/scipy/torch objects out of the venv. Put
# them only on the .app and the app launches fine, then dies on `import numpy`.
# Every bundled runtime directory, not just python-*: a new one (uv, #94) must
# not ship unsigned merely because nobody updated this glob.
for runtime in "${APP_PATH}/Contents/Resources"/python-* "${APP_PATH}/Contents/Resources"/uv-*; do
    [ -d "${runtime}" ] || continue
    echo "  signing bundled runtime $(basename "${runtime}")"

    # Libraries first, interpreters last — inside-out, as above.
    while IFS= read -r macho; do
        case "${macho}" in
            */bin/python*) continue ;;   # handled below, with entitlements
        esac
        echo "    lib $(basename "${macho}")"
        sign_ts "${macho}"
    done < <(find "${runtime}" -type f -print0 | xargs -0 file 2>/dev/null \
             | grep "Mach-O" | cut -d: -f1)

    while IFS= read -r interpreter; do
        echo "    interpreter $(basename "${interpreter}") (with entitlements)"
        sign_ts --entitlements "${ENTITLEMENTS}" "${interpreter}"
    done < <(find "${runtime}/bin" -type f -name "python3*" -print0 2>/dev/null \
             | xargs -0 file 2>/dev/null | grep "Mach-O" | cut -d: -f1)
done

# Sign the outer app last, with entitlements. No --deep: nested code is already
# signed above.
echo "  signing ${APP_PATH}"
sign_ts --entitlements "${ENTITLEMENTS}" "${APP_PATH}"

# Verify the whole tree
echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
echo "  ✓ ${APP_PATH} signed successfully"
echo "  Identity: ${IDENTITY}"
