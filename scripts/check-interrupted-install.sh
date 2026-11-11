#!/usr/bin/env bash
# An install cut short is finished on the next launch, not started from (#51).
#
# Quitting during an update's package install left an environment with
# PsyNeuLink but no server packages. The next launch took it for ready, the
# server died with "No module named uvicorn", and the Starting window counted
# for twenty minutes. The unit tests modelled a half-built environment that an
# interrupted install never produces, so nothing caught it.
#
# This leaves the real shape behind and relaunches: it marks the current
# install's environment as still installing and removes uvicorn, then requires
# the app to finish the install by itself, come up healthy, and mark the
# environment complete.
#
# Run after a first launch has set the app up (scripts/measure-boot.sh does,
# unattended).
set -euo pipefail

DOMAIN="com.psyneuview.macapp"
current="$(defaults read "$DOMAIN" repoPath)"
venv="$current/backend/.venv"
[ -d "$venv" ] || { echo "no environment at '$venv' — run measure-boot first" >&2; exit 2; }
marker="$venv/.psyneuview-setup"

site="$(ls -d "$venv"/lib/python*/site-packages | head -1)"
[ -d "$site/uvicorn" ] || { echo "uvicorn isn't installed in '$site' to begin with" >&2; exit 2; }

# The state an interrupted install leaves: unfinished, and no server.
rm -rf "$site"/uvicorn "$site"/uvicorn-*.dist-info
printf 'installing\n' > "$marker"
echo "Left an interrupted install at $venv (marked installing, uvicorn removed)."

# The breakdown of a first launch is kept elsewhere; this one is a repair.
BOOT_BREAKDOWN="${BOOT_BREAKDOWN:-.build/boot-breakdown-interrupted.json}" \
  ./scripts/measure-boot.sh "${1:-0.25}"

if [ ! -d "$site/uvicorn" ]; then
  echo "interrupted: the app started without reinstalling uvicorn" >&2
  exit 1
fi
state="$(tr -d '[:space:]' < "$marker" 2>/dev/null || true)"
if [ "$state" != "complete" ]; then
  echo "interrupted: the environment is marked '${state:-nothing}', not complete" >&2
  exit 1
fi
echo "interrupted: the app finished the install by itself, and started."
