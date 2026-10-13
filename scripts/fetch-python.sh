#!/bin/bash
#
# Download and unpack the bundled CPython runtime into Resources/python-<version>/.
#
# Idempotent: re-running with the runtime already present is a no-op, so `make
# app` can depend on it without re-downloading 25 MB every build.
#
# Usage: ./scripts/fetch-python.sh
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/python-runtime.conf

DEST="Resources/python-${PYTHON_VERSION}"
INTERPRETER="${DEST}/bin/python3"

if [ -x "${INTERPRETER}" ]; then
    echo "  ✓ Python ${PYTHON_VERSION} runtime already present"
    exit 0
fi

ASSET="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-${PBS_TRIPLE}-${PBS_VARIANT}.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${ASSET//+/%2B}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Fetching CPython ${PYTHON_VERSION} (${PBS_TRIPLE})..."
curl -fsSL -o "${TMP}/python.tar.gz" "${URL}"

echo "Verifying checksum..."
ACTUAL="$(shasum -a 256 "${TMP}/python.tar.gz" | awk '{print $1}')"
if [ "${ACTUAL}" != "${PBS_SHA256}" ]; then
    echo "Error: checksum mismatch for ${ASSET}" >&2
    echo "  expected ${PBS_SHA256}" >&2
    echo "  actual   ${ACTUAL}" >&2
    exit 1
fi

tar xzf "${TMP}/python.tar.gz" -C "${TMP}"
rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
mv "${TMP}/python" "${DEST}"

# Confirm it runs and reports the version we pinned, before anything depends on it.
GOT="$("${INTERPRETER}" --version 2>&1 | awk '{print $2}')"
if [ "${GOT}" != "${PYTHON_VERSION}" ]; then
    echo "Error: unpacked interpreter reports ${GOT}, expected ${PYTHON_VERSION}" >&2
    exit 1
fi

echo "  ✓ CPython ${PYTHON_VERSION} unpacked to ${DEST}"
