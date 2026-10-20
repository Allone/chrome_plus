#!/usr/bin/env bash
# Fast Linux syntax check for the Windows sources.
#
# Runs a Windows-targeting cross compiler over every translation unit in src/
# with -fsyntax-only, so broken code is caught in seconds instead of waiting
# for the Windows matrix in build.yml. It is a *syntax/semantic* gate only: no
# object files, no linking, no MSVC codegen (CMakeLists.txt refuses non-MSVC
# frontends, and build.cmd remains the authoritative build).
#
# Two MSVC-only constructs in the tree need bridging (see .github/msvc-compat/):
# MSVC's `0x1ui64` literal suffix (src/green.cc) and SAL's legacy `__in`
# spelling. GCC handles both through a shim; clang cannot, because it parses
# reserved literal suffixes before macro expansion. So GCC is the compiler used
# here, and nothing about this script changes the real MSVC build.
#
# Coverage caveat, reported rather than hidden: src/utils.cc uses C++23
# `std::ranges::to`, which lives in libstdc++ -- and when cross compiling that
# comes from the mingw-w64 package, not the host. The mingw-w64 GCC on GitHub
# runners is 13.x, which lacks it, while a desktop install is typically 14+.
# The script probes for the feature and, when it is missing, says exactly which
# file is uncovered instead of exiting green on a partial check.
#
# Usage: .github/scripts/linux-syntax-check.sh [file.cc ...]
#   CXX=<compiler>  override the cross compiler (default x86_64-w64-mingw32-g++)

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

cxx="${CXX:-x86_64-w64-mingw32-g++}"
if ! command -v "$cxx" >/dev/null 2>&1; then
  echo "error: $cxx not found (Debian/Ubuntu: apt-get install g++-mingw-w64-x86-64)" >&2
  exit 1
fi

probe="$(mktemp -d)"
shim_dir="$(mktemp -d)"
trap 'rm -rf "$probe" "$shim_dir"' EXIT

for dep in detours/src/detours.h mini_gzip/mini_gzip.h; do
  if [[ ! -f "$dep" ]]; then
    echo "error: $dep missing -- run: git submodule update --init --recursive" >&2
    exit 1
  fi
done

cp .github/msvc-compat/*.h "$shim_dir/"

# pakfile.cc writes `#include "..\mini_gzip\mini_gzip.h"` with Windows path
# separators. Include paths are resolved with host semantics, so on Linux that
# is one literal file name rather than a directory traversal. Expose the header
# under exactly that name inside a -iquote directory: the include then resolves
# without dropping a backslash-named file into the working tree.
ln -s "$root/mini_gzip/mini_gzip.h" "$shim_dir/..\\mini_gzip\\mini_gzip.h"

# Feature probe: `std::ranges::to` needs libstdc++ 14+, and the library that
# matters is the one shipped for the *target*, not the host.
cat >"$probe/ranges_to.cc" <<'CPP'
#include <ranges>
#include <vector>
int main() {
  std::vector<int> values{1, 2};
  auto result = values | std::ranges::to<std::vector>();
  (void)result;
}
CPP
have_ranges_to=false
if "$cxx" -std=c++23 -fsyntax-only "$probe/ranges_to.cc" >/dev/null 2>&1; then
  have_ranges_to=true
fi

flags=(
  -std=c++23
  -fsyntax-only
  -DUNICODE
  -D_UNICODE
  -Isrc
  -Idetours/src
  -Imini_gzip
  -iquote "$shim_dir"
  -include "$shim_dir/mingw-shim.h"
  # The shim's `operator"" ui64` trips GCC's reserved-suffix pedantry.
  -Wno-literal-suffix
)

# SAL macros are scoped to the single file that uses them; see green-shim.h.
shim_for() {
  case "$1" in
    src/green.cc) echo "-include $shim_dir/green-shim.h" ;;
  esac
}

if (($#)); then
  files=("$@")
else
  files=(src/*.cc)
fi

# Files the toolchain cannot parse, kept separate from genuine failures so a
# missing C++23 library is never mistaken for a broken edit.
uncovered=()
failed=()
for file in "${files[@]}"; do
  if ! $have_ranges_to && grep -q 'std::ranges::to' "$file" 2>/dev/null; then
    uncovered+=("$file")
    printf 'SKIP  %-28s (needs C++23 std::ranges::to)\n' "$file"
    continue
  fi

  extra=()
  read -r -a extra <<<"$(shim_for "$file")"
  if log="$("$cxx" "${flags[@]}" "${extra[@]}" "$file" 2>&1)"; then
    printf 'PASS  %s\n' "$file"
  else
    printf 'FAIL  %s\n' "$file"
    printf '%s\n' "$log" | sed 's/^/      /'
    failed+=("$file")
  fi
done

checked=$(( ${#files[@]} - ${#uncovered[@]} ))
echo
echo "checked $checked file(s), $(( ${#failed[@]} )) failed"

if ((${#uncovered[@]})); then
  cat >&2 <<EOF

warning: $cxx cannot compile C++23 std::ranges::to, so the following file(s)
were not checked:
$(printf '  %s\n' "${uncovered[@]}")

Its libstdc++ is $("$cxx" -dM -E - </dev/null 2>/dev/null |
    awk '$2 == "__GNUC__" { print "GCC " $3 }') and the feature needs GCC 14+.
On GitHub runners the mingw-w64 package is 13.x, so this is expected there;
install a newer cross compiler locally to cover the file.
EOF
fi

if ((${#failed[@]} || ${#uncovered[@]})); then
  {
    echo "### Linux syntax check"
    echo
    echo "| result | file |"
    echo "| --- | --- |"
    for file in "${files[@]}"; do
      status="PASS"
      for bad in "${failed[@]}"; do
        [[ "$file" == "$bad" ]] && status="**FAIL**"
      done
      for skipped in "${uncovered[@]}"; do
        [[ "$file" == "$skipped" ]] && status="skipped"
      done
      echo "| $status | \`$file\` |"
    done
    if ((${#uncovered[@]})); then
      echo
      echo "Skipped files need a newer mingw-w64 toolchain than the runner"
      echo "provides (C++23 \`std::ranges::to\`, GCC 14+)."
    fi
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

((${#failed[@]})) && exit 1
exit 0
