#!/bin/sh
# Assert build (LUA_USE_ASSERT + LUA_USE_APICHECK) running the d54 corpus
# with a side trace after the first taken exit (-Ohotexit=1). Side-trace
# replay inherits its parent's snapshot slot types (lj_snap_replay); in
# particular an I64 loop slot whose value wrapped into the int32 range is
# restored canonically as an int32, and rec_check_slots must accept that
# state (the replayed I64 SLOAD's runtime guard exits there).
#
# Red before the rec_check_slots fix (d54/numeric_07_hot_intfloat.lua and
# d54/i64_02_jit.lua aborted with "slot N type mismatch: stack type 13 vs
# IR type 21").
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
OUT=${CI_BOX_OUT:-/tmp/ci-box}
AB="$OUT/assertbuild"
rm -rf "$AB"
mkdir -p "$AB"
cp -r src dynasm Makefile etc "$AB/"
( cd "$AB/src" && make clean >/dev/null 2>&1 || true )
( cd "$AB" && make -j"$NPROC" CFLAGS="-DLUA_USE_ASSERT -DLUA_USE_APICHECK" \
    >"$OUT-assertbuild.log" 2>&1 ) || { tail -30 "$OUT-assertbuild.log"; exit 1; }
"$AB/src/luajit" -v | head -1
LUAJIT="$AB/src/luajit" tests/harness.sh --strict --mode B \
  --corpus tests/d54 --timeout 120 --jit-args="-Ohotexit=1"
