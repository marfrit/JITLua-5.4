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
"$OUT/test_capi"
"$OUT/test_i64"