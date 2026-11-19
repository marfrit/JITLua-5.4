#!/bin/sh
# Build luasystem 0.4.4 (pinned, vendored) against the public JITLua-5.4
# headers and load the resulting system.core module under -joff and -jon.
#
# luasystem 0.4.4's src/time.c uses INT_MAX without including <limits.h>; it
# must come transitively from luaconf.h, exactly as with PUC 5.4.9's headers.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SRC=${LUAINC:-$ROOT/src}
LUAJIT=${LUAJIT:-$ROOT/src/luajit}
CC=${CC:-gcc}
TARBALL="$ROOT/tests/capi/dist/luasystem-0.4.4.tar.gz"
SHA256=d20786035f5d5a9ab3555813a3e495516efeba32909007ca0155a73d7695ee4a

[ -x "$LUAJIT" ] || { echo "luasystem: $LUAJIT missing -- run make -j" >&2; exit 2; }
got=$(sha256sum "$TARBALL" | cut -d' ' -f1)
if [ "$got" != "$SHA256" ]; then
  echo "luasystem: sha256 mismatch for $TARBALL" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $got" >&2
  exit 1
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT INT TERM
tar xzf "$TARBALL" -C "$W"
D="$W/luasystem-0.4.4"

$CC -O2 -fPIC -shared -I"$SRC" -o "$W/core.so" "$D"/src/*.c -lrt -lm
mkdir -p "$W/system"
cp "$W/core.so" "$W/system/core.so"

run() { # run <jit-flag> <label>
  LUA_CPATH="$W/?.so;;" "$LUAJIT" "$1" -e '
    local core = require "system.core"
    assert(core._VERSION == "LuaSystem 0.4.4",
           "unexpected version " .. tostring(core._VERSION))
    assert(type(core.gettime) == "function", "system.gettime missing")
    assert(type(core.monotime) == "function", "system.monotime missing")
    print("luasystem: OK " .. core._VERSION .. " " .. "'"$2"'")
  '
}

run -joff "joff"
run -jon "jon"
