#!/bin/bash
#
# Download the pinned uv binary into Resources/uv-<version>/. (#94)
#
# Idempotent, so `make app` can depend on it without re-downloading.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/uv-runtime.conf

DEST="Resources/uv-${UV_VERSION}"
BINARY="${DEST}/uv"

if [ -x "${BINARY}" ]; then
    echo "  ✓ uv ${UV_VERSION} already present"
    exit 0
fi

ASSET="uv-aarch64-apple-darwin.tar.gz"
URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${ASSET}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Fetching uv ${UV_VERSION}..."
curl -fsSL -o "${TMP}/uv.tar.gz" "${URL}"

echo "Verifying checksum..."
ACTUAL="$(shasum -a 256 "${TMP}/uv.tar.gz" | awk '{print $1}')"
if [ "${ACTUAL}" != "${UV_SHA256}" ]; then
    echo "Error: checksum mismatch for ${ASSET}" >&2
    echo "  expected ${UV_SHA256}" >&2
    echo "  actual   ${ACTUAL}" >&2
    exit 1
fi

tar xzf "${TMP}/uv.tar.gz" -C "${TMP}"
rm -rf "${DEST}"; mkdir -p "${DEST}"
find "${TMP}" -name uv -type f -perm +111 -exec cp {} "${BINARY}" \;
[ -x "${BINARY}" ] || { echo "Error: no uv binary in ${ASSET}" >&2; exit 1; }

GOT="$("${BINARY}" --version | awk '{print $2}')"
[ "${GOT}" = "${UV_VERSION}" ] || { echo "Error: unpacked uv reports ${GOT}, expected ${UV_VERSION}" >&2; exit 1; }
echo "  ✓ uv ${UV_VERSION} unpacked to ${DEST}"
