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
PUC_SRC=$(ls -d "$ROOT"/tests/ref/src/lua-*/src 2>/dev/null | head -1 || true)
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
PUC_SRC="$ROOT/tests/ref/src/lua-5.4.9/src"
if [ -f "$PUC_SRC/liblua.a" ] && [ -f "$PUC_SRC/lua.h" ]; then
  $CC $CFLAGS -I"$PUC_SRC" "$ROOT/tests/capi/probe_549.c" \
    -o "$OUT/probe_549_puc" "$PUC_SRC/liblua.a" \
    $LDFLAGS -lm -ldl -lpthread
  echo "== probe_549 (PUC 5.4.9 reference) =="
  "$OUT/probe_549_puc"
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

# Source-compatible, not binary-compatible: the same probe source built
# against PUC 5.4.9 headers must be rejected at luaL_checkversion, and built
# against ours it must load and use lua_upvalueindex/LUA_REGISTRYINDEX.
mkdir -p "$OUT/abi/jit"
ABI_OK=0
$CC $CFLAGS -shared -fPIC -I"$SRC" "$ROOT/tests/capi/abi_probe.c" \
  -o "$OUT/abi/jit/abi_probe.so" $LDFLAGS && ABI_OK=1
if [ "$ABI_OK" = 1 ] && [ -x "$MODLUAJIT" ]; then
  echo "== abi_probe (JITLua headers) =="
  LUA_CPATH="$OUT/abi/jit/?.so;;" "$MODLUAJIT" -joff "$ROOT/tests/capi/abi_probe.lua"
  LUA_CPATH="$OUT/abi/jit/?.so;;" "$MODLUAJIT" -jon  "$ROOT/tests/capi/abi_probe.lua"
fi
if [ -n "${PUC_SRC:-}" ] && [ -f "$PUC_SRC/lua.h" ]; then
  mkdir -p "$OUT/abi/puc"
  if $CC $CFLAGS -shared -fPIC -I"$PUC_SRC" "$ROOT/tests/capi/abi_probe.c" \
       -o "$OUT/abi/puc/abi_probe.so" $LDFLAGS; then
    if [ -x "$MODLUAJIT" ]; then
      echo "== abi_probe (PUC 5.4.9 headers, must be rejected) =="
      LUA_CPATH="$OUT/abi/puc/?.so;;" "$MODLUAJIT" -joff "$ROOT/tests/capi/abi_probe_reject.lua"
      LUA_CPATH="$OUT/abi/puc/?.so;;" "$MODLUAJIT" -jon  "$ROOT/tests/capi/abi_probe_reject.lua"
    fi
  else
    echo "capi: PUC-header abi_probe build failed (reference headers unusable)"
  fi
else
  echo "capi: skipping PUC-header abi_probe (no reference source, run tests/ref/fetch-ref.sh)"
fi

# Bare-state parity check against the vendored PUC 5.4.9 when its source tree is
# present (ci-box.sh builds it before this stage). A build failure is skipped
# (e.g. a reference tree copied from another architecture); a run that fails is
# a real parity break and fails the stage.
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
