#!/bin/sh
# One-shot verification for a clean, possibly offline machine (build box).
#
#   x64-build -t 3600 tests/ci-box.sh              # x64 build box
#   sh tests/ci-box.sh                             # here (aarch64)
#
# Builds our LuaJIT, builds the PUC-Lua 5.4.9 reference from the vendored
# tarball (tests/ref/dist, no network needed), then runs the differential
# harness for the port corpus in modes A and B at several JIT opt levels,
# plus the C API harness. Prints a compact report; artifacts stay local.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
OUT=${CI_BOX_OUT:-/tmp/ci-box}

say() { printf '\n=== %s ===\n' "$*"; }

say "machine"
uname -m
echo "nproc $NPROC"

say "build LuaJIT"
make clean >/dev/null 2>&1 || true
make -j"$NPROC" >"$OUT-build.log" 2>&1 || { tail -30 "$OUT-build.log"; exit 1; }
./src/luajit -v | head -1
# 5.4 needs two number types: check the number model explicitly, because
# x64/x86 default to single-number mode unless LUAJIT_NUMMODE=2 is set.
./src/luajit -joff -e 'print("nummodel: math.type(3) = " .. tostring(math.type(3)) .. " (must be integer)")'

say "build reference (PUC-Lua 5.4.9, vendored tarball)"
# A copied tree can carry a reference binary built for another architecture
# (e.g. aarch64 on the x64 box): always check that it actually runs.
if ! tests/ref/bin/lua54ref -v >/dev/null 2>&1; then
  rm -f tests/ref/bin/lua54ref tests/ref/bin/luac54ref
  tests/ref/fetch-ref.sh --force >"$OUT-ref.log" 2>&1 || { tail -30 "$OUT-ref.log"; exit 1; }
fi
tests/ref/bin/lua54ref -v | head -1

say "harness: modes A+B (port corpus)"
tests/harness.sh --mode both --corpus tests/d54 --timeout 120 | tail -12

say "harness: mode B at opt levels 0..3"
tests/harness.sh --mode B --opt-levels 0,1,2,3 --corpus tests/d54 --timeout 120 | tail -12

say "harness: dump/reload (mode R)"
tests/harness.sh --mode R --corpus tests/d54 --timeout 120 | tail -12
echo "=== lib checks ==="
for j in -joff -jon; do timeout 120 ./src/luajit $j tests/lib/bit-checkint.lua || exit 1; done
for j in -joff -jon; do timeout 120 ./src/luajit $j tests/lib/ffrec-54.lua || exit 1; done
# x64 math.random/negative-int-key JIT bug (known-bad math B): hangs on the
# buggy build, so bound it.
for j in -joff -O0 -O3; do timeout 120 ./src/luajit $j tests/lib/math-random-jit.lua || exit 1; done

say "harness: GC stress (pause 0 in every arm), int64 + close tests, modes A+B+R"
tests/harness.sh --mode all --opt-levels 0,3 --gc-stress --corpus tests/d54 \
  --filter 'i64_' --filter 'close_' --filter 'coro_' --filter 'gc_' --filter 'bits_' --timeout 300 | tail -12

say "JIT tooling smoke (-jv/-jdump/-jbc/-jp over the int64 tests)"
sh tests/jitutil-smoke.sh | tail -4

say "real-program corpus (tests/corpus-ext: PUC vs -joff / -jon / -jon+GC-stress)"
sh tests/corpus-ext/run.sh | grep -v "^      " | tail -44

say "C API"
tests/capi/run.sh | grep -E '^== (capi|i64):'

say "fuzz: mode B, 40 programs x opt levels 0-3, GC pressure"
python3 tests/fuzz/fuzz.py --seed 1 --count 40 --mode B --opt-levels 0,1,2,3 --gc | tail -6

say "done"
