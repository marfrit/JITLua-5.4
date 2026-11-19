#!/bin/sh
# Object-layout check for the x86_64 reference layouts, GC64 and non-GC64.
#
#   sh tests/nogc64-layout.sh
#   make layout-check
#
# LuaJIT-5.4 adds fields to GC objects (GCproto.envuv, the envv TValue in
# GCfuncHeader). lj_obj.h pins the GChead-shared fields with LJ_STATIC_ASSERT,
# but those asserts only run in a configuration that is actually compiled. The
# non-GC64 x86_64 build (make CFLAGS=-DLUAJIT_DISABLE_GC64) is otherwise never
# built, and a fork commit turned upstream's
#     #if LJ_GC64
#       uint32_t unused_gc64;
#     #endif
# into an unconditional field, which moved GCproto.gclist off the GChead
# offset for the 32 bit GCRef layout. It surfaced as a failing assert in a
# host translation unit, with nothing in the gate to point at the cause.
#
# This compiles one header-only translation unit for x86_64 in BOTH layouts:
# every lj_obj.h assert is evaluated there, plus the ones below that name the
# fork's additions. It needs no VM, no JIT and no buildvm -- it is a fraction
# of a second, so it belongs in the gate.
#
# Scope: the object layout only. The non-GC64 x86_64 build also needs a VM for
# 32 bit GC references (src/Makefile picks vm_x86.dasc when LJ_FR2 is off),
# which does not carry the 5.4 port yet; see docs/DIFFERENCES.md, "Platform
# scope".
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CC=${CC:-cc}
OUT=${NOGC64_LAYOUT_OUT:-/tmp/nogc64-layout}

if [ "$(uname -m)" != x86_64 ]; then
  echo "nogc64-layout: x86_64 only, skipped on $(uname -m)"
  exit 0
fi

cat >"$OUT.c" <<'EOF'
#include <stdio.h>
#include "lj_obj.h"
#include "lj_i64.h"
#include "lj_frame.h"

/* Repeated on purpose: these name the fork's additions, so a failure points
** here and not at an unrelated line in lj_obj.h. */
LJ_STATIC_ASSERT(offsetof(GChead, gclist) == offsetof(GCproto, gclist));
LJ_STATIC_ASSERT(offsetof(GChead, gclist) == offsetof(GCfuncL, gclist));
LJ_STATIC_ASSERT(offsetof(GChead, gclist) == offsetof(GCtab, gclist));
LJ_STATIC_ASSERT(offsetof(GChead, gclist) == offsetof(lua_State, gclist));
LJ_STATIC_ASSERT(offsetof(GChead, env) == offsetof(GCfuncL, env));
LJ_STATIC_ASSERT(offsetof(GChead, metatable) == offsetof(GCtab, metatable));

/* The _ENV debug slot must sit in the GC64 padding before gclist, or after
** the fields that follow it in the 32 bit layout -- never between. */
LJ_STATIC_ASSERT((LJ_GC64 &&
		  offsetof(GCproto, envuv) < offsetof(GCproto, gclist)) ||
		 (!LJ_GC64 &&
		  offsetof(GCproto, envuv) > offsetof(GCproto, gclist)));

/* The widened 47-bit inline integer only exists in the GC64 NaN-box; with
** 32 bit GC references the tag word has no payload bits to test. */
LJ_STATIC_ASSERT((LJ_GC64 && sizeof(GCRef) == 8) ||
		 (!LJ_GC64 && sizeof(GCRef) == 4));

int main(void)
{
  printf("GC64 %d: GCproto gclist %zu envuv %zu size %zu | "
	 "GCfunc env %zu envv %zu | GCtab gclist %zu | TValue %zu\n",
	 (int)LJ_GC64,
	 (size_t)offsetof(GCproto, gclist), (size_t)offsetof(GCproto, envuv),
	 (size_t)sizeof(GCproto),
	 (size_t)offsetof(GCfuncL, env), (size_t)offsetof(GCfuncC, envv),
	 (size_t)offsetof(GCtab, gclist), (size_t)sizeof(TValue));
  return 0;
}
EOF

FAILED=""
# src/Makefile forces -DLUAJIT_NUMMODE=2 for every build (5.4 needs both
# number types and x64 would default to single-number mode), so the check has
# to set it too -- via the preprocessor here, exactly as CFLAGS would.
for mode in gc64 nogc64; do
  flags="-DLUAJIT_NUMMODE=2"
  [ "$mode" = nogc64 ] && flags="$flags -DLUAJIT_DISABLE_GC64"
  printf '%-8s ' "$mode"
  if $CC -c -o "$OUT.o" -I"$ROOT/src" $flags "$OUT.c" 2>"$OUT.err"; then
    cc -o "$OUT.bin" "$OUT.o" 2>>"$OUT.err" && "$OUT.bin" || echo "link failed"
  else
    echo "COMPILE FAILED"
    sed 's/^/    /' "$OUT.err"
    FAILED="$FAILED $mode"
  fi
done
rm -f "$OUT.c" "$OUT.o" "$OUT.bin" "$OUT.err"

if [ -n "$FAILED" ]; then
  echo "nogc64-layout: FAILED ($FAILED)"
  exit 1
fi
echo "nogc64-layout: layouts ok"
