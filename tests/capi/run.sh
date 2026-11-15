#!/bin/sh
# Build and run the C API conformance tests against the freshly built LuaJIT.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SRC="$ROOT/src"
OUT="$ROOT/tests/capi/build"
mkdir -p "$OUT"
CC=${CC:-gcc}
[ -x "$SRC/luajit" ] || (cd "$ROOT" && make -j"$(nproc)")
"$CC" -O2 -g -I"$SRC" "$ROOT/tests/capi/test_capi.c" -o "$OUT/test_capi" \
  "$SRC/libluajit.a" -lm -ldl
"$CC" -O2 -g -I"$SRC" "$ROOT/tests/capi/test_i64.c" -o "$OUT/test_i64" \
  "$SRC/libluajit.a" -lm -ldl
"$OUT/test_capi"
"$OUT/test_i64"