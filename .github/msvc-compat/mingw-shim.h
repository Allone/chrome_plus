// CI-only compatibility shims so the Linux syntax check (MinGW-GCC) can parse
// sources written for MSVC. Nothing here is shipped: the real build always runs
// MSVC/clang-cl on Windows (CMakeLists.txt rejects non-MSVC frontends, and
// build.cmd is the authoritative build).
//
// Deliberately macro-free: this header is force-included before every source
// file, so it must not define object-like macros (SAL annotations live in
// green-shim.h, which is only used for src/green.cc).
#ifdef __GNUC__

// MSVC integer suffix, e.g. `0x00000001ui64 << 44` in green.cc. clang cannot
// use this shim (it parses reserved suffixes before overload resolution), which
// is why the check uses GCC.
constexpr unsigned long long operator"" ui64(unsigned long long value) {
  return value;
}

// MSVC intrinsic used by hijack.cc's NOP_FUNC; MinGW's <intrin.h> does not
// declare `__nop`.
inline void __nop() {}

// UI Automation's TreeScope enum is spelled `TreeScope_Subtree` in the SDK
// MSVC builds against, but newer mingw-w64 headers renamed it to
// `TreeScope_SubTree`. Normalise so src/uia.cc keeps the MSVC spelling.
#include <uiautomationclient.h>
#if defined(TreeScope_SubTree) && !defined(TreeScope_Subtree)
#define TreeScope_Subtree TreeScope_SubTree
#endif

#endif  // __GNUC__
