#!/bin/bash
#
# Fetch the pinned PsyNeuView revision, build its frontend, and stage the result
# as Resources/psyneuview-<version>.tar.gz for bundling into the app. (#74)
#
# Runs on the BUILD machine, never on a user's. Node is needed here to produce
# frontend/dist — which is why no user ever needs Node installed (#65).
#
# Idempotent: re-running with the archive already present is a no-op.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/psyneuview-pin.conf

ARCHIVE="Resources/psyneuview-${PSYNEUVIEW_VERSION}.tar.gz"

if [ -f "${ARCHIVE}" ]; then
    echo "  ✓ PsyNeuView ${PSYNEUVIEW_VERSION} already staged"
    exit 0
fi

command -v node >/dev/null || { echo "Error: node is required to build the frontend" >&2; exit 1; }
command -v curl >/dev/null || { echo "Error: curl is required to fetch PsyNeuView" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Fetching PsyNeuView ${PSYNEUVIEW_REF}..."
# Public repo: no token needed. One is still sent when set (GH_TOKEN), which
# raises the API rate limit on shared CI machines.
AUTH=()
[ -n "${GH_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GH_TOKEN}")
curl -fsSL "${AUTH[@]+"${AUTH[@]}"}" \
    "https://api.github.com/repos/${PSYNEUVIEW_REPO}/tarball/${PSYNEUVIEW_REF}" > "${TMP}/src.tar.gz"
mkdir -p "${TMP}/src"
tar xzf "${TMP}/src.tar.gz" -C "${TMP}/src" --strip-components=1

SRC="${TMP}/src"
[ -d "${SRC}/backend" ]  || { echo "Error: no backend/ in the fetched tree" >&2; exit 1; }
[ -d "${SRC}/frontend" ] || { echo "Error: no frontend/ in the fetched tree" >&2; exit 1; }

echo "Building the frontend (this is why users never need Node)..."
(
    cd "${SRC}/frontend"
    npm ci --silent 2>&1 | tail -2 || npm install --silent 2>&1 | tail -2
    node node_modules/.bin/vite build 2>&1 | tail -3
)
[ -f "${SRC}/frontend/dist/index.html" ] || { echo "Error: frontend build produced no dist/index.html" >&2; exit 1; }

# Stage only what the app runs. docs/ alone is ~15 MB of screenshots, and none of
# it is needed at runtime.
STAGE="${TMP}/stage/psyneuview-${PSYNEUVIEW_VERSION}"
mkdir -p "${STAGE}/frontend"
cp -R "${SRC}/backend"        "${STAGE}/backend"
cp -R "${SRC}/frontend/dist"  "${STAGE}/frontend/dist"
[ -d "${SRC}/models" ] && cp -R "${SRC}/models" "${STAGE}/models"

# Anything the fetch dragged in that must not ship.
rm -rf "${STAGE}/backend/.venv" "${STAGE}/backend/__pycache__"
find "${STAGE}" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "${STAGE}" -name "*.pyc" -delete 2>/dev/null || true

# When that PsyNeuView was released: the date of the commit the tag points to,
# so About can say how recent it is (#15). Best effort: a failed lookup leaves
# it empty and About leaves the date out.
RELEASED="$(curl -fsSL "${AUTH[@]+"${AUTH[@]}"}" \
    "https://api.github.com/repos/${PSYNEUVIEW_REPO}/commits/${PSYNEUVIEW_REF}" 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["commit"]["committer"]["date"])' 2>/dev/null \
    || true)"
[ -n "${RELEASED}" ] || echo "  (couldn't look up when ${PSYNEUVIEW_REF} was released; About will leave the date out)"

cat > "${STAGE}/BUNDLED_VERSION" <<VERSION
version=${PSYNEUVIEW_VERSION}
ref=${PSYNEUVIEW_REF}
repo=${PSYNEUVIEW_REPO}
released=${RELEASED}
VERSION

mkdir -p Resources
tar czf "${ARCHIVE}" -C "${TMP}/stage" "psyneuview-${PSYNEUVIEW_VERSION}"

echo "  ✓ staged ${ARCHIVE} ($(du -h "${ARCHIVE}" | awk '{print $1}'))"
