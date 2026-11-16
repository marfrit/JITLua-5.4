#!/bin/sh
# JIT tooling smoke test: -jv, -jdump, -jbc and -jp must survive the int64
# corpus (boxed and widened literals, int64 table keys, int64 fast-function
# arguments). jit.util hands trace constants and proto constants to Lua
# code (jit/dump.lua, jit/bc.lua, jit/v.lua), which once segfaulted on boxed
# literals; this keeps that path exercised on both arches.
#
#   sh tests/jitutil-smoke.sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
LUAJIT=${LUAJIT:-$ROOT/src/luajit}
export LUA_PATH="$ROOT/src/?.lua;;"
fail=0; n=0
for s in tests/d54/i64_02_jit.lua tests/d54/i64_03_jit_tables.lua \
         tests/d54/i64_04_keys.lua tests/d54/i64_05_lib.lua \
         tests/d54/bits_02_metamethods.lua tests/d54/close_01_semantics.lua; do
  for o in -jbc -jv "-jdump=bimT" "-jdump=+rs" -jp; do
    n=$((n+1))
    "$LUAJIT" $o "$s" >/tmp/jitutil-smoke.txt 2>&1; rc=$?
    if [ $rc -ne 0 ]; then
      fail=1; printf 'FAIL %s %s rc=%d\n' "$s" "$o" "$rc"; tail -3 /tmp/jitutil-smoke.txt
    fi
  done
done
printf '== jitutil smoke: %d runs, %s ==\n' "$n" "$([ $fail = 0 ] && echo ok || echo FAILURES)"
exit $fail
