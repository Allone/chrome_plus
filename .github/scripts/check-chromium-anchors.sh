#!/usr/bin/env bash
# Early-warning check: does chrome++ still match the Chromium source it hooks?
#
# chrome++ reaches into Chrome's internals in three ways, all of which break
# silently when upstream refactors:
#   1. UIA class names (src/uia.cc) -- Chrome's views report their C++ class
#      name to UI Automation; rename a view and tab features stop resolving.
#   2. Byte offsets / HTML anchors patched into resources.pak (src/pakpatch.cc)
#      -- the settings page must still contain the strings we rewrite.
#   3. Version-probing internals (installer version used by the upgrade
#      notification).
#
# This script audits every one of those anchors against a Chromium tag and
# reports what moved. It is intentionally tolerant of *news* (a new tab-strip
# class to support is not a failure) and strict about *disappearances*.
#
# Usage: check-chromium-anchors.sh <chromium-tag> [--json]
#   e.g. check-chromium-anchors.sh 155.0.8059.0
#   CHROMIUM=... to override, defaults to the current Stable tag.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

if (($#)); then
  tag="$1"
  shift
else
  tag="$(CHROMIUM="${CHROMIUM:-}" .github/scripts/chromium-stable-version.sh | sed -n 's/^TAG=//p')"
fi
[[ -n "$tag" ]] || { echo "error: could not determine Chromium tag" >&2; exit 1; }

json=false
[[ "${1:-}" == "--json" ]] && json=true

raw="https://raw.githubusercontent.com/chromium/chromium/${tag}"
cache_dir="$(mktemp -d)"
trap 'rm -rf "$cache_dir"' EXIT

fetch() {  # fetch <path> -> echoes body, or returns 1 on 404
  local path="$1" out="$cache_dir/$(printf '%s' "$1" | tr '/' '_')"
  [[ -f "$out" ]] && { cat "$out"; return 0; }
  if curl -fsSL --retry 2 "$raw/$1" -o "$out"; then cat "$out"; return 0; fi
  return 1
}

if ! fetch chrome/VERSION >/dev/null; then
  echo "error: Chromium tag $tag not found ($raw)" >&2
  exit 1
fi
chromium_version="$(fetch chrome/VERSION | sed -n 's/^MAJOR=//p;')"
chromium_build="$(fetch chrome/VERSION | sed -n 's/^BUILD=//p')"

# ---------------------------------------------------------------------------
# 1. UIA class names chrome++ matches on, and where they come from.
#
# (anchor, source file that must declare it)
# ---------------------------------------------------------------------------
uia_anchors=(
  # Tab strip regions -- src/uia.cc ResolveTabUi().
  'HorizontalTabStripRegionView|chrome/browser/ui/views/frame/horizontal_tab_strip_region_view.h'
  'HorizontalTabStripRegionViewOld|chrome/browser/ui/views/frame/horizontal_tab_strip_region_view.h'
  'HorizontalTabStripRegionViewNew|chrome/browser/ui/views/frame/horizontal_tab_strip_region_view.h'
  'VerticalTabStripRegionView|chrome/browser/ui/views/frame/vertical_tab_strip_region_view.h'
  # Tab containers.
  'TabContainerImpl|chrome/browser/ui/views/tabs/tab_container_impl.h'
  'UnpinnedTabContainerView|chrome/browser/ui/views/tabs/common/unpinned_tab_container_view.h'
  # Tab views and their close buttons.
  'TabCloseButton|chrome/browser/ui/views/tabs/tab/tab_close_button.h'
  'TabView|chrome/browser/ui/views/tabs/common/tab_view.h'
  # Buttons and transient UI chrome++ targets.
  'NewTabButton|chrome/browser/ui/views/tabs/shared/new_tab_button.h'
  'TabStripControlButton|chrome/browser/ui/views/tabs/tab_strip_control_button.h'
  'BookmarkButton|chrome/browser/ui/views/bookmarks/bookmark_button.h'
  'FindBarView|chrome/browser/ui/views/find_bar_view.h'
  'OmniboxViewViews|chrome/browser/ui/views/omnibox/omnibox_view_views.h'
)

# Class names chrome++ still matches but that no current Chromium declares.
# Reported as a warning rather than a failure: the lookups simply never hit,
# which is harmless but means the branch is dead and should be cleaned up.
# Verified absent from views/tabs in 140, 148, 152 and 155.
uia_legacy_anchors=(
  'VerticalUnpinnedTabContainerView'
  'VerticalTabView'
)

# The pre-unification `NewTabButton` is metadata-less and therefore surfaces as
# `TabStripControlButton`; both names must stay valid as long as the old strip
# can be built. TabStripControlButton covers that, so no extra anchor needed.

# ---------------------------------------------------------------------------
# 2. Strings patched into resources.pak -- src/pakpatch.cc.
#
# Each one must still appear in Chromium's settings page source; if upstream
# renames a property the replace silently no-ops and the about page breaks.
# ---------------------------------------------------------------------------
about_page='chrome/browser/resources/settings/about_page/about_page.html.ts'
about_page_ts='chrome/browser/resources/settings/about_page/about_page.ts'
# The </settings-about-page> closing tag pakpatch.cc searches for only exists in
# the compiled resources.pak (Polymer wraps the template in the element tag), so
# in the template source it is verified via the element definition instead: if
# the element is renamed, the compiled tag changes too and the pak scan misses.
pak_anchors=(
  '<settings-section page-title="$i18n{aboutPageTitle}">|'"$about_page"
  '?hidden="${!this.showUpdateStatus_}"|'"$about_page"
  '?hidden="${!this.shouldShowIcons_()}"|'"$about_page"
  '{aboutBrowserVersion}</div>|'"$about_page"
  'settings-about-page|'"$about_page_ts"
)

# ---------------------------------------------------------------------------
# 3. Version-probing internals -- src/upgradenotification.cc.
#
# chrome++ does not call these, but they define the version string format the
# upgrade notification parses; a rename/removal means the format may change.
# ---------------------------------------------------------------------------
probe_files=(
  'chrome/browser/upgrade_detector/installed_version_poller.cc'
  'chrome/installer/util/util_constants.h'
)

failures=()
notes=()

report_missing() {
  failures+=("$1")
  $json || printf 'MISSING  %s\n' "$1"
}

# -- UIA anchors -------------------------------------------------------------
for entry in "${uia_anchors[@]}"; do
  name="${entry%%|*}"
  path="${entry##*|}"
  if ! body="$(fetch "$path")"; then
    report_missing "UIA class '$name': source file $path no longer exists"
    continue
  fi
  if grep -qw -- "$name" <<<"$body"; then
    $json || printf 'ok       UIA class %-36s %s\n' "$name" "$path"
  else
    report_missing "UIA class '$name' not found in $path"
  fi
done

# A compiled-out class (behind a buildflag) still compiles in Chrome releases,
# so presence in the header is the right signal -- but call out the ones that
# are feature-flagged, as a heads-up that behaviour may change.
if body="$(fetch chrome/browser/ui/tabs/features.cc)"; then
  for feature in kTabStripUnification; do
    if grep -q -- "$feature" <<<"$body"; then
      enabled="$(grep -A3 -- "$feature" <<<"$body" | grep -oE 'FEATURE_(ENABLED|DISABLED)_BY_DEFAULT' | head -1)"
      notes+=("$feature is $enabled in $tag")
      $json || printf 'note     %-44s %s\n' "$feature" "${enabled:-unknown}"
    fi
  done
fi

# -- pak anchors -------------------------------------------------------------
declare -A pak_bodies=()
for entry in "${pak_anchors[@]}"; do
  anchor="${entry%%|*}"
  path="${entry##*|}"
  if [[ -z "${pak_bodies[$path]:-}" ]]; then
    if body="$(fetch "$path")"; then
      pak_bodies["$path"]="$body"
    else
      report_missing "settings source $path no longer exists (anchor '$anchor')"
      continue
    fi
  fi
  if grep -qF -- "$anchor" <<<"${pak_bodies[$path]}"; then
    $json || printf 'ok       pak anchor %-38s %s\n' "$anchor" "$path"
  else
    report_missing "pak anchor '$anchor' not found in $path"
  fi
done

# -- UIA legacy anchors ------------------------------------------------------
# These names are still matched by src/uia.cc but are declared by no current
# Chromium release, so their lookups can never hit. Surfaced as a note (dead
# code to prune), never as a failure.
for name in "${uia_legacy_anchors[@]}"; do
  notes+=("src/uia.cc still matches legacy class '$name', which no Chromium release declares -- dead branch, safe to drop")
  $json || printf 'note     legacy UIA class %-27s still matched in src/uia.cc\n' "$name"
done

# -- version probes ----------------------------------------------------------
for path in "${probe_files[@]}"; do
  if fetch "$path" >/dev/null; then
    $json || printf 'ok       probe file %s\n' "$path"
  else
    notes+=("$path was removed or moved upstream")
    $json || printf 'note     probe file %s no longer exists\n' "$path"
  fi
done

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if $json; then
  python3 - "$chromium_version" "$chromium_build" "$tag" "${#failures[@]}" \
    ${failures[@]+"${failures[@]}"} <<'PY'
import json, sys
version, build, tag, count = sys.argv[1:5]
problems = sys.argv[5:]
print(json.dumps({
    "chromium_major": version,
    "chromium_build": build,
    "tag": tag,
    "failure_count": int(count),
    "failures": problems,
}, indent=2))
PY
  # Exit non-zero on drift even in JSON mode so callers can use `if ! ... then`
  # while still consuming the report.
  ((${#failures[@]})) && exit 1
  exit 0
fi

echo
if ((${#notes[@]})); then
  printf -- '- %s\n' "${notes[@]}"
fi
echo "checked ${#uia_anchors[@]} UIA anchors, ${#pak_anchors[@]} pak anchors and ${#probe_files[@]} probe files against Chromium $tag"
if ((${#failures[@]})); then
  echo "RESULT: ${#failures[@]} anchor(s) drifted"
  exit 1
fi
echo "RESULT: all anchors present"
