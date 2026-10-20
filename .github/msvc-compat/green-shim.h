// CI-only shim, force-included for src/green.cc only (the one source file
// using SAL's legacy `__in` spelling). Not part of the real MSVC build.
//
// Why the include list is duplicated below: `__in`/`__out` are *ordinary
// identifiers* inside libstdc++ (std::ostream, structured bindings in
// <algorithm>, ...), so a library-wide `-D__in=` would shred the standard
// library. Defining the macros only after green.cc's own headers are parsed
// keeps them scoped to green.cc's actual code -- exactly the situation MSVC
// sees, where sal.h defines `__in` for this TU and no system header spells
// parameters that way.
//
// Keep the list below in sync with the #include block at the top of
// src/green.cc; if green.cc gains an include, add it here too (a missing
// entry shows up as a loud syntax failure, not as a silent pass).
#include "green.h"

#include <windows.h>

#include <lmaccess.h>
#include <processthreadsapi.h>
#include <shlwapi.h>

#include "detours.h"

#include "config.h"
#include "utils.h"

// SAL annotations that the MinGW Windows SDK headers do not provide. The set
// below is exactly the SAL vocabulary used by src/ (see also the `__`-prefixed
// identifier audit in the workflow): anything new shows up as a compile error
// rather than being silently ignored.
#define __in
#define __out
#define __inout
#define __in_opt
#define __out_opt
#define __inout_opt
#define __in_bcount_opt(_size)
#define __out_bcount_opt(_size)

// MSVC's `0x...ui64` integer suffix (used in the enum just below these
// includes). GCC accepts it through the user-defined literal in mingw-shim.h,
// but clang parses the suffix before overload resolution and rejects it, so
// neutralise it textually instead. Safe here because every header green.cc
// includes was already parsed above -- the macro cannot reach a system header.
#ifdef __clang__
#define ui64
#endif
