#!/usr/bin/env bash
# Prints the newest Chromium *Stable* milestone as VERSION / TAG / MAJOR.
#
# The Chromium Dash API is the source of truth (VERSIONS / STABLE); the tag is
# the milestone branch point Chromium publishes as `<MAJOR>.0.<BUILD>.0`. The
# VERSION file of that tag is re-read to confirm the tag exists and to report
# the real build number, so a wrong tag surfaces here instead of as confusing
# 404s during the anchor check.
#
# Usage: chromium-stable-version.sh [--github-output]
#   --github-output  also append VERSION=/TAG=/MAJOR= to $GITHUB_OUTPUT

set -euo pipefail

emit_github=false
[[ "${1:-}" == "--github-output" ]] && emit_github=true

api='https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=1'

payload="$(curl -fsSL --retry 3 --retry-delay 2 "$api")"
version="$(printf '%s' "$payload" | python3 -c '
import json, sys
releases = json.load(sys.stdin)
if not releases:
    raise SystemExit("no Stable release returned by Chromium Dash")
print(releases[0]["version"])
')"

major="${version%%.*}"
build="$(printf '%s' "$version" | cut -d. -f3)"
tag="${major}.0.${build}.0"

raw="https://raw.githubusercontent.com/chromium/chromium/${tag}/chrome/VERSION"
if ! curl -fsSL -o /dev/null "$raw"; then
  echo "error: tag $tag does not exist in chromium/chromium" >&2
  exit 1
fi

if $emit_github; then
  {
    echo "VERSION=$version"
    echo "TAG=$tag"
    echo "MAJOR=$major"
  } >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
else
  echo "VERSION=$version"
  echo "TAG=$tag"
  echo "MAJOR=$major"
fi
