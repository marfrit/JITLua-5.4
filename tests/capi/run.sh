#!/bin/sh
# Build and run the C API conformance tests against the freshly built LuaJIT.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SRC=${LUAINC:-$ROOT/src}
OUT=${CAPI_OUT:-$ROOT/tests/capi/build}
mkdir -p "$OUT"
CC=${CC:-gcc}
CFLAGS=${CFLAGS:--O2 -g}
LDFLAGS=${LDFLAGS:-}
LIB=${LUAJIT_LIB:-$SRC/libluajit.a}
[ -f "$LIB" ] || (cd "$ROOT" && make -j"$(nproc)")
$CC $CFLAGS -I"$SRC" "$ROOT/tests/capi/test_capi.c" -o "$OUT/test_capi" \
  "$LIB" $LDFLAGS -lm -ldl
$CC $CFLAGS -I"$SRC" "$ROOT/tests/capi/test_i64.c" -o "$OUT/test_i64" \
  "$LIB" $LDFLAGS -lm -ldl
$CC $CFLAGS -I"$SRC" "$ROOT/tests/capi/test_extraspace.c" -o "$OUT/test_extraspace" \
  "$LIB" $LDFLAGS -lm -ldl
"$OUT/test_capi"
"$OUT/test_i64"
"$OUT/test_extraspace"

# C API parity probe for the DIFFERENCES.md entries that are only observable
# from C (print-only except two parity asserts; the PUC side is the oracle).
$CC $CFLAGS -I"$SRC" "$ROOT/tests/capi/probe_549.c" -o "$OUT/probe_549" \
  "$LIB" $LDFLAGS -lm -ldl
echo "== probe_549 (JITLua-5.4) =="
"$OUT/probe_549"
PUC_DIR=$(ls -d "$ROOT"/tests/ref/src/lua-*/src 2>/dev/null | head -1 || true)
if [ -n "${PUC_DIR:-}" ] && [ -d "$PUC_DIR" ]; then
  [ -f "$PUC_DIR/liblua.a" ] || (cd "$PUC_DIR" && make a -j"$(nproc)")
  if [ -f "$PUC_DIR/liblua.a" ]; then
    $CC $CFLAGS -I"$PUC_DIR" "$ROOT/tests/capi/probe_549.c" \
      -o "$OUT/probe_549_puc" "$PUC_DIR/liblua.a" \
      $LDFLAGS -lm -ldl -lpthread
    echo "== probe_549 (PUC 5.4.9 reference) =="
    "$OUT/probe_549_puc"
  else
    echo "== probe_549 (PUC side skipped: reference libs failed to build) =="
  fi
else
  echo "== probe_549 (PUC side skipped: reference source missing, run tests/ref/fetch-ref.sh) =="
fi

# Public-header probe for the module-facing macros (no <limits.h> include in
# the probe itself) and the real third-party module that exposed the gap.
# MODLUAJIT is the host interpreter used to load the modules; it defaults to
# the freshly built one and may point at a sanitizer/assert build.
MODLUAJIT=${MODLUAJIT:-$ROOT/src/luajit}
$CC $CFLAGS -shared -fPIC -I"$SRC" "$ROOT/tests/capi/headers_probe.c" \
  -o "$OUT/headers_probe.so" $LDFLAGS
if [ -x "$MODLUAJIT" ]; then
  echo "== headers_probe (public headers, probes never include <limits.h>) =="
  LUA_CPATH="$OUT/?.so;;" "$MODLUAJIT" -joff "$ROOT/tests/capi/headers_probe.lua"
  LUA_CPATH="$OUT/?.so;;" "$MODLUAJIT" -jon  "$ROOT/tests/capi/headers_probe.lua"
  echo "== luasystem 0.4.4 (pinned) built and loaded =="
  LUAINC="$SRC" LUAJIT="$MODLUAJIT" CC="$CC" sh "$ROOT/tests/capi/luasystem.sh"
else
  echo "capi: modules compiled but not loaded (no host interpreter at $MODLUAJIT)"
fi

# Bare-state parity check against the vendored PUC 5.4.9 when its source tree is
# present (ci-box.sh builds it before this stage). A build failure is skipped
# (e.g. a reference tree copied from another architecture); a run that fails is
# a real parity break and fails the stage.
PUC_SRC="$ROOT/tests/ref/src/lua-5.4.9/src"
if [ -f "$PUC_SRC/liblua.a" ] && [ -f "$PUC_SRC/lua.h" ]; then
  if $CC $CFLAGS -I"$PUC_SRC" "$ROOT/tests/capi/bare_state_ref.c" \
       -o "$OUT/bare_state_ref" "$PUC_SRC/liblua.a" $LDFLAGS -lm -ldl \
       >"$OUT/bare_state_ref.build.log" 2>&1; then
    "$OUT/bare_state_ref"
  else
    echo "capi: skipping PUC bare-state comparison (reference build unavailable)"
    tail -3 "$OUT/bare_state_ref.build.log" 2>/dev/null || true
  fi
else
  echo "capi: skipping PUC bare-state comparison (no reference source tree)"
fi
