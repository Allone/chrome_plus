// CI-only compatibility shims so the Linux syntax check (MinGW-GCC) can
// parse sources written for MSVC. Nothing here is shipped: the real build
// always runs MSVC/clang-cl on Windows (CMakeLists.txt rejects non-MSVC
// frontends, and build.cmd is the authoritative build).
//
// Deliberately macro-free: this header is force-included before every source
// file, so it must not define object-like macros (SAL annotations live in
// green-shim.h, which is only used for src/green.cc).
#ifdef __GNUC__

// MSVC integer suffix, e.g. `0x00000001ui64 << 44` in green.cc.
constexpr unsigned long long operator""ui64(unsigned long long value) {
  return value;
}

// MSVC intrinsic used by hijack.cc's NOP_FUNC; MinGW's <intrin.h> does not
// declare `__nop`.
inline void __nop() {}

#endif  // __GNUC__
