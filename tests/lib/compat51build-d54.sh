#!/bin/sh
# 5.1-compat build: a second build of the same source with the switch on,
# CFLAGS=-DLUAJIT_ENABLE_51COMPAT.
#
# The default build must not define the Lua 5.1 leftovers (that is a d54
# corpus test, compat51_01_51names_absent.lua). This stage proves the other
# half of the switch: with it, every name is there and works, the generated
# library tables follow the switch (buildvm sees the same CFLAGS), and the
# tests that build userdata with newproxy run again -- they report a skip in
# the default build, so this is where their coverage lives.
#
#   sh tests/lib/compat51build-d54.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
OUT=${CI_BOX_OUT:-/tmp/ci-box}
CB="$OUT/compat51build"
rm -rf "$CB"
mkdir -p "$CB"
cp -r src dynasm Makefile etc "$CB/"
( cd "$CB/src" && make clean >/dev/null 2>&1 || true )
( cd "$CB" && make -j"$NPROC" CFLAGS="-DLUAJIT_ENABLE_51COMPAT" \
    >"$OUT-compat51build.log" 2>&1 ) || { tail -30 "$OUT-compat51build.log"; exit 1; }
"$CB/src/luajit" -v | head -1
# The switch is visible in the library tables buildvm generated for this build.
"$CB/src/luajit" -e 'print("names:", type(unpack), type(loadstring), type(gcinfo), type(newproxy), type(module), type(table.getn), type(table.foreach), type(package.loaders), type(package.seeall))'
# And absent from the default build in this tree.
./src/luajit -e 'print("default:", tostring(unpack), tostring(loadstring), tostring(gcinfo), tostring(newproxy), tostring(module), tostring(table.getn), tostring(table.foreach), tostring(package.loaders), tostring(package.seeall))'
for j in -joff -jon; do
  "$CB/src/luajit" $j tests/lib/compat51-check.lua || exit 1
done
# The newproxy-based files: skipped in the default build, real here (mode B).
# The compat51_01 corpus file is deliberately not in this run: it asserts the
# names are absent, which is the default build.
LUAJIT="$CB/src/luajit" tests/harness.sh --strict --mode B --corpus tests/d54 \
  --filter 'env_07' --filter 'udfin_' --filter 'jit_05' --timeout 120
echo "compat51 build: ok"
