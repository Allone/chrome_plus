// CI-only compatibility shims so the Linux syntax check can parse sources
// written for MSVC. Nothing here is shipped: the real build always runs
// MSVC/clang-cl on Windows (CMakeLists.txt rejects non-MSVC frontends, and
// build.cmd is the authoritative build).
//
// Used by both the GCC and clang cross compilers, so everything below must be
// valid for either frontend.
//
// Deliberately macro-free: this header is force-included before every source
// file, so it must not define object-like macros (SAL annotations live in
// green-shim.h, which is only used for src/green.cc).
#if defined(__GNUC__) || defined(__clang__)

// MSVC integer suffix, e.g. `0x00000001ui64 << 44` in green.cc. The space
// before `ui64` is required: without it C++11+ reads the suffix as one token
// and clang rejects it outright.
constexpr unsigned long long operator"" ui64(unsigned long long value) {
  return value;
}

// MSVC intrinsic used by hijack.cc's NOP_FUNC; the MinGW <intrin.h> does not
// declare `__nop`.
inline void __nop() {}

// UI Automation's TreeScope enum is spelled `TreeScope_Subtree` in the SDK
// MSVC builds against, but newer mingw-w64 headers renamed it to
// `TreeScope_SubTree`. Normalise so src/uia.cc keeps the MSVC spelling.
#include <uiautomationclient.h>
#if defined(TreeScope_SubTree) && !defined(TreeScope_Subtree)
#define TreeScope_Subtree TreeScope_SubTree
#endif

#endif  // __GNUC__ || __clang__
