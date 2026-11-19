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
