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

# ASan+UBSan.  NOTE: -DLUAJIT_USE_SYSMALLOC (which lets ASan see LuaJIT's
# heap) currently fails to start on arm64+GC64: the system allocator returns
# addresses outside LuaJIT's 47-bit GC range ("cannot create state: not enough
# memory").  We therefore sanitize with LuaJIT's own allocator: stack/global
# overflows and UB are still caught, heap overflows inside the allocator are
# not.  Revisit with a low-address allocator hint (Phase 6 hardening).
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
      CC="gcc -fsanitize=address,undefined -fno-sanitize=alignment -fno-omit-frame-pointer -g" \
      HOST_CC="gcc" CCDEBUG="-g" \
      LDFLAGS="-fsanitize=address,undefined -fno-sanitize=alignment" )
fi
if ! ASAN_OPTIONS=detect_leaks=0 "$SANBUILD/src/luajit" -e 'os.exit(0)' >/dev/null 2>&1; then
  echo "ci-local: sanitizer binary cannot start (allocator/address-space issue)" >&2
  exit 2
fi
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 \
  UBSAN_OPTIONS=print_stacktrace=0:halt_on_error=1 \
  LUAJIT="$SANBUILD/src/luajit" tests/harness.sh --mode all --corpus tests/d54 --timeout 120
# C API stage under the sanitizers: compile the harness and tests with the same
# instrumentation, link the instrumented libluajit.a and run them.
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 \
  UBSAN_OPTIONS=print_stacktrace=0:halt_on_error=1 \
  LUAJIT_LIB="$SANBUILD/src/libluajit.a" LUAINC="$SANBUILD/src" \
  MODLUAJIT="$SANBUILD/src/luajit" \
  CAPI_OUT="$SANBUILD/capi-build" \
  CC="gcc -fsanitize=address,undefined -fno-sanitize=alignment -fno-omit-frame-pointer -g" \
  LDFLAGS="-fsanitize=address,undefined -fno-sanitize=alignment" \
  tests/capi/run.sh
# C API checks also under -DLUA_USE_ASSERT -DLUA_USE_APICHECK: the ordinary
# sanitizer build does not enable LuaJIT's API assertions, so a broken buffer
# stack discipline or an invalid rotation would pass unnoticed.
# Only --sanitizers-only rebuilds this; a normal ci-local run reuses an
# existing assert build when present.
ASSERTBUILD="$ROOT/tests/ref/assertbuild"
if [ ! -f "$ASSERTBUILD/src/libluajit.a" ] || [ "$SAN" = 1 ]; then
  rm -rf "$ASSERTBUILD"
  mkdir -p "$ASSERTBUILD"
  cp -r "$ROOT/src" "$ROOT/dynasm" "$ROOT/Makefile" "$ROOT/etc" "$ASSERTBUILD/"
  ( cd "$ASSERTBUILD/src" && make clean >/dev/null 2>&1 || true )
  ( cd "$ASSERTBUILD" && ASAN_OPTIONS=detect_leaks=0 make -j"$(nproc)" \
      CFLAGS="-DLUA_USE_ASSERT -DLUA_USE_APICHECK" HOST_CC="gcc" \
      >/tmp/ci-local-assert-build.log 2>&1 ) || {
    tail -30 /tmp/ci-local-assert-build.log; exit 1; }
fi
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=print_stacktrace=0:halt_on_error=1 \
  LUAJIT_LIB="$ASSERTBUILD/src/libluajit.a" LUAINC="$ASSERTBUILD/src" \
  MODLUAJIT="$ASSERTBUILD/src/luajit" \
  CAPI_OUT="$ASSERTBUILD/capi-build" tests/capi/run.sh
echo "ci-local: OK"
