#!/bin/sh
# Local CI equivalent (MISSION Phase 0): normal + ASan/UBSan builds, full harness,
# short differential fuzz.  Usage: tests/ci-local.sh [--sanitizers-only] [--quick]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
SAN=0; QUICK=0
for a in "$@"; do case "$a" in --sanitizers-only) SAN=1;; --quick) QUICK=1;; esac; done

[ -x tests/ref/bin/lua54ref ] || tests/ref/fetch-ref.sh

if [ "$SAN" = 0 ]; then
  make -j"$(nproc)" >/dev/null
  tests/harness.sh --mode all --timeout 120
  tests/capi/run.sh
  N=200; [ "$QUICK" = 1 ] && N=40
  python3 tests/fuzz/fuzz.py --seed 1 --count "$N" --mode B --opt-levels 0,1,2,3 --gc
  python3 tests/fuzz/fuzz.py --seed 1 --count "$N" --mode R --gc
fi

# ASan+UBSan.  LUAJIT_USE_SYSMALLOC is required: LuaJIT's bundled allocator
# hides overflows from ASan.  LSan is off until Phase 4 (GC/finalizer port).
SANBUILD="$ROOT/tests/ref/sanbuild"
if [ ! -x "$SANBUILD/src/luajit" ] || [ "$SAN" = 1 ]; then
  rm -rf "$SANBUILD"
  mkdir -p "$SANBUILD"
  cp -r "$ROOT/src" "$ROOT/dynasm" "$ROOT/Makefile" "$ROOT/etc" "$SANBUILD/"
  ( cd "$SANBUILD/src" && make clean >/dev/null 2>&1 || true )
  # HOST_CC defaults to $(CC); keep the host build tools (buildvm/minilua)
  # uninstrumented -- they are short-lived and leak by design, which would
  # otherwise abort the build under LSan.
  ( cd "$SANBUILD" && ASAN_OPTIONS=detect_leaks=0 make -j"$(nproc)" \
      CC="gcc -fsanitize=address,undefined -fno-omit-frame-pointer -g" \
      HOST_CC="gcc" \
      XCFLAGS="-DLUAJIT_USE_SYSMALLOC" LDFLAGS="-fsanitize=address,undefined" )
fi
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1 \
  LUAJIT="$SANBUILD/src/luajit" tests/harness.sh --mode all --corpus tests/d54 --timeout 120
echo "ci-local: OK"
