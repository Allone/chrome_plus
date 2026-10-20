#!/usr/bin/env bash
# Fast Linux syntax check for the Windows sources.
#
# Runs a Windows-targeting cross compiler over every translation unit in src/
# with -fsyntax-only, so broken code is caught in seconds instead of waiting
# for the Windows matrix in build.yml. It is a *syntax/semantic* gate only: no
# object files, no linking, no MSVC codegen (CMakeLists.txt refuses non-MSVC
# frontends, and build.cmd remains the authoritative build).
#
# Two frontends are needed because the sources use two MSVC-only constructs
# that no single non-MSVC compiler accepts:
#
#   * src/utils.cc uses C++23 `std::ranges::to`, which needs a recent standard
#     library. The mingw-w64 cross GCC on GitHub runners is 13.x and lacks it,
#     while clang (using libstdc++'s newer headers) has it.
#   * src/green.cc uses MSVC's `0x1ui64` literal suffix. clang parses reserved
#     suffixes before macro expansion and rejects any shim, GCC accepts one.
#
# So clang is the primary compiler and GCC covers green.cc. Both are probed
# for the capability they are used for, so a surprising toolchain fails with an
# actionable message instead of a standard-library error that looks like a bug
# in chrome++.
#
# See .github/msvc-compat/ for the CI-only shims; nothing here changes the
# real build.
#
# Usage: .github/scripts/linux-syntax-check.sh [file.cc ...]
#   CLANGXX=<compiler>  override the primary cross compiler
#   CXX=<compiler>      override the fallback cross compiler

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

clangxx="${CLANGXX:-clang++}"
gccxx="${CXX:-x86_64-w64-mingw32-g++}"
target='x86_64-w64-windows-gnu'

probe="$(mktemp -d)"
shim_dir="$(mktemp -d)"
trap 'rm -rf "$probe" "$shim_dir"' EXIT

# Capability probes: the question is "can this compiler parse what the sources
# actually use", which no version number answers.
cat >"$probe/ranges_to.cc" <<'CPP'
#include <ranges>
#include <vector>
int main() {
  std::vector<int> values{1, 2};
  auto result = values | std::ranges::to<std::vector>();
  (void)result;
}
CPP
# The UI Automation enum is spelled whichever way the SDK does; check that the
# shim's normalisation reaches the name src/uia.cc uses.
cat >"$probe/ui64.cc" <<'CPP'
int value = 0x1ui64;
CPP

supports_std_ranges_to() {
  command -v "$1" >/dev/null 2>&1 || return 1
  "$1" --target="$target" -std=c++23 -fsyntax-only "$probe/ranges_to.cc" \
    >/dev/null 2>&1
}

supports_ui64_shim() {
  command -v "$1" >/dev/null 2>&1 || return 1
  "$1" -std=c++23 -fsyntax-only -Wno-literal-suffix \
    -include "$shim_dir/mingw-shim.h" "$probe/ui64.cc" >/dev/null 2>&1
}

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

if ! supports_std_ranges_to "$clangxx"; then
  echo "error: $clangxx cannot compile C++23 std::ranges::to, which" >&2
  echo "src/utils.cc uses. hint: apt-get install clang" >&2
  exit 1
fi
if ! supports_ui64_shim "$gccxx"; then
  echo "error: $gccxx cannot compile MSVC's 0x1ui64 literal through the shim," >&2
  echo "which src/green.cc uses. hint: apt-get install g++-mingw-w64-x86-64" >&2
  exit 1
fi

clang_flags=(
  --target="$target"
  -std=c++23
  -fsyntax-only
  -DUNICODE
  -D_UNICODE
  -Isrc
  -Idetours/src
  -Imini_gzip
  -iquote "$shim_dir"
)
gcc_flags=(
  -std=c++23
  -fsyntax-only
  -DUNICODE
  -D_UNICODE
  -Isrc
  -Idetours/src
  -Imini_gzip
  -iquote "$shim_dir"
  # The shim's `operator"" ui64` trips GCC's reserved-suffix pedantry.
  -Wno-literal-suffix
)

# src/green.cc is the only file needing the fallback compiler and the only one
# needing the SAL shim; see green-shim.h.
use_gcc() { [[ "$1" == src/green.cc ]]; }

if (($#)); then
  files=("$@")
else
  files=(src/*.cc)
fi

compiler_for() {
  if use_gcc "$1"; then echo "$gccxx"; else echo "$clangxx"; fi
}

failed=()
for file in "${files[@]}"; do
  extra=()
  if use_gcc "$file"; then
    extra=("${gcc_flags[@]}" -include "$shim_dir/mingw-shim.h"
           -include "$shim_dir/green-shim.h")
  else
    extra=("${clang_flags[@]}" -include "$shim_dir/mingw-shim.h")
  fi
  if log="$("$(compiler_for "$file")" "${extra[@]}" "$file" 2>&1)"; then
    printf 'PASS  %-28s (%s)\n' "$file" "$(basename "$(compiler_for "$file")")"
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
    echo "| result | file | compiler |"
    echo "| --- | --- | --- |"
    for file in "${files[@]}"; do
      status="PASS"
      for bad in "${failed[@]}"; do
        [[ "$file" == "$bad" ]] && status="**FAIL**"
      done
      echo "| $status | \`$file\` | \`$(basename "$(compiler_for "$file")")\` |"
    done
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
fi
