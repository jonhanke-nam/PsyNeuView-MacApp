#!/bin/bash
#
# Print the release notes for a tag, and optionally an HTML rendering for the
# Sparkle update dialog.
#
#   ./scripts/tag-notes.sh v0.5.5            # plain text (GitHub Releases)
#   ./scripts/tag-notes.sh v0.5.5 --html     # HTML (appcast <description>)
#
# The annotated tag message is the single source. It is written at tag time, when
# whoever cut the release knows what is in it — rather than reconstructed later
# from commit subjects, or replaced by a static template that goes stale. The
# template previously used for GitHub Releases still told users they needed
# "Python 3.9+, Node.js 18+, SSH key configured for GitHub", none of which has
# been true since the app started bundling its own.
set -euo pipefail

TAG="${1:-}"
[ -n "${TAG}" ] || { echo "usage: $0 <tag> [--html]" >&2; exit 1; }

# Refuse unless this is a real annotated tag.
#
# git resolves a tag name to its commit when the tag object is absent — which is
# the default in CI, where actions/checkout does not fetch tag objects. The first
# version of this script fell back to %(contents) in that case, so 0.5.5 shipped
# with "Merge pull request #112" as its release notes. A wrong answer that looks
# like an answer is worse than an error.
OBJECT_TYPE="$(git cat-file -t "${TAG}" 2>/dev/null || echo missing)"
if [ "${OBJECT_TYPE}" != "tag" ]; then
    echo "error: ${TAG} is not an annotated tag object (got '${OBJECT_TYPE}')." >&2
    echo "  Release notes come from the tag message — see RELEASING.md." >&2
    echo "  In CI this usually means actions/checkout needs fetch-depth: 0." >&2
    exit 1
fi

# `contents:body` is the message without its first line, which we drop because
# GitHub already shows it as the release title.
BODY="$(git tag -l --format='%(contents:body)' "${TAG}")"
if [ -z "${BODY}" ]; then
    echo "error: ${TAG} has an empty message; there are no release notes to publish." >&2
    exit 1
fi

if [ "${2:-}" != "--html" ]; then
    printf '%s\n' "${BODY}"
    exit 0
fi

# Minimal, deliberate conversion for Sparkle: paragraphs and dash lists. Anything
# cleverer risks mangling a message written for humans reading plain text.
printf '%s\n' "${BODY}" | python3 -c '
import html, sys
lines = sys.stdin.read().splitlines()
out, in_list = [], False
para: list[str] = []

def flush_para():
    global para
    if para:
        out.append("<p>" + html.escape(" ".join(para)) + "</p>")
        para = []

for line in lines:
    stripped = line.strip()
    if stripped.startswith("- "):
        flush_para()
        if not in_list:
            out.append("<ul>"); in_list = True
        out.append("<li>" + html.escape(stripped[2:]) + "</li>")
    elif not stripped:
        flush_para()
        if in_list:
            out.append("</ul>"); in_list = False
    else:
        # Continuation of a list item wraps into it; otherwise it is prose.
        if in_list and line.startswith("  "):
            out[-1] = out[-1][:-5] + " " + html.escape(stripped) + "</li>"
        else:
            para.append(stripped)
flush_para()
if in_list:
    out.append("</ul>")
print("\n".join(out))
'
