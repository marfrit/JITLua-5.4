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
