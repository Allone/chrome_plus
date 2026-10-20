#!/usr/bin/env bash
# Fast Linux syntax check for the Windows sources.
#
# Runs MinGW-GCC over every translation unit in src/ with -fsyntax-only, so
# broken code is caught in seconds on ubuntu-latest instead of waiting for the
# Windows matrix in build.yml. It is a *syntax/semantic* gate only: no object
# files, no linking, no MSVC codegen (CMakeLists.txt refuses non-MSVC
# frontends, and build.cmd remains the authoritative build).
#
# The three MSVC-only constructs in the tree (see .github/msvc-compat/) are
# bridged by a CI-only shim header; nothing here changes the real build.
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

# src/utils.cc uses `std::ranges::to` (C++23). GCC only gained it in 14 while
# the Debian/Ubuntu mingw-w64 cross package still ships GCC 13 even on Ubuntu
# 26.04, so probing by version is wrong in both directions. Feature-test the
# compiler directly: if `std::ranges::to` parses, the toolchain is adequate.
probe="$(mktemp -d)"
shim_dir="$(mktemp -d)"
trap 'rm -rf "$probe" "$shim_dir"' EXIT
cat >"$probe/ranges_to.cc" <<'CPP'
#include <ranges>
#include <vector>
int main() {
  std::vector<int> values{1, 2};
  auto result = values | std::ranges::to<std::vector>();
  (void)result;
}
CPP
if ! "$cxx" -std=c++23 -fsyntax-only "$probe/ranges_to.cc" >/dev/null 2>&1; then
  echo "error: $cxx cannot compile C++23 std::ranges::to, which src/utils.cc uses." >&2
  echo "hint: install a newer cross compiler, e.g." >&2
  echo "      sudo apt-get install g++-mingw-w64-x86-64-posix gcc-mingw-w64-x86-64-posix" >&2
  exit 1
fi

for dep in detours/src/detours.h mini_gzip/mini_gzip.h; do
  if [[ ! -f "$dep" ]]; then
    echo "error: $dep missing -- run: git submodule update --init --recursive" >&2
    exit 1
  fi
done

cp .github/msvc-compat/*.h "$shim_dir/"

# pakfile.cc writes `#include "..\mini_gzip\mini_gzip.h"` with Windows path
# separators. GCC resolves include paths with host semantics, so on Linux that
# is one literal file name rather than a directory traversal. Expose the
# header under exactly that name inside a -iquote directory: the include then
# resolves without dropping a backslash-named file into the working tree.
ln -s "$root/mini_gzip/mini_gzip.h" "$shim_dir/..\\mini_gzip\\mini_gzip.h"

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
  # The shim's `operator""ui64` trips GCC's reserved-suffix pedantry.
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

failed=()
for file in "${files[@]}"; do
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

echo
echo "checked ${#files[@]} file(s), $(( ${#failed[@]} )) failed"

if ((${#failed[@]})); then
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
      echo "| $status | \`$file\` |"
    done
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
fi
