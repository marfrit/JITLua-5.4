#!/bin/sh
# One-shot verification for a clean, possibly offline machine (build box).
#
#   x64-build -t 3600 tests/ci-box.sh              # x64 build box
#   sh tests/ci-box.sh                             # here (aarch64)
# (x64-build is a private wrapper that runs a command on a remote x86_64 test
# host.)
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

# Every stage keeps its own exit status. Output is filtered for the compact
# report, but a stage that fails marks the whole run as failed (a pipe into
# tail would otherwise always succeed).
FAILED=""
stage() {  # stage <filter> <command...>
  _flt=$1; shift
  _log=$(mktemp)
  _rc=0
  "$@" >"$_log" 2>&1 || _rc=$?
  sh -c "$_flt" <"$_log" || true
  rm -f "$_log"
  if [ "$_rc" -ne 0 ]; then
    echo "!! stage failed (rc=$_rc): $*"
    FAILED="$FAILED [$*]"
  fi
}

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

say "GC policy modes (LUAJIT_GC / -G)"
stage 'tail -20' sh tests/gcmode.sh

say "object layout, both x86_64 reference layouts (GC64 / non-GC64)"
stage 'cat' sh tests/nogc64-layout.sh

say "build reference (PUC-Lua 5.4.9, vendored tarball)"
# A copied tree can carry a reference binary built for another architecture
# (e.g. aarch64 on the x64 box): always check that it actually runs.
if ! tests/ref/bin/lua54ref -v >/dev/null 2>&1; then
  rm -f tests/ref/bin/lua54ref tests/ref/bin/luac54ref
  tests/ref/fetch-ref.sh --force >"$OUT-ref.log" 2>&1 || { tail -30 "$OUT-ref.log"; exit 1; }
fi
tests/ref/bin/lua54ref -v | head -1

say "harness self-test (known-bad / known-different handling)"
stage 'tail -16' sh tests/lib/runner-selftest.sh

say "harness: modes A+B (port corpus)"
stage 'tail -12' tests/harness.sh --strict --mode both --corpus tests/d54 --timeout 120

say "harness: mode B at opt levels 0..3"
stage 'tail -12' tests/harness.sh --strict --mode B --opt-levels 0,1,2,3 --corpus tests/d54 --timeout 120

say "harness: dump/reload (mode R)"
stage 'tail -12' tests/harness.sh --strict --mode R --corpus tests/d54 --timeout 120

say "assert build (LUA_USE_ASSERT + APICHECK): d54 corpus with -Ohotexit=1"
# rec_check_slots compares the recorder's slot types with the interpreter's
# stack at every recorded instruction; with hotexit=1 every taken exit gets a
# side trace, which starts from its parent's slot types (red before the
# recorder narrowed an inherited int64 slot that came back as an int32:
# d54/numeric_07*, i64_02*).
stage 'tail -16' sh tests/lib/assertbuild-d54.sh

say "5.1-compat build (CFLAGS=-DLUAJIT_ENABLE_51COMPAT) and its checks"
stage 'tail -20' sh tests/lib/compat51build-d54.sh
echo "=== lib checks ==="
for j in -joff -jon; do timeout 120 ./src/luajit $j tests/lib/bit-checkint.lua || exit 1; done
for j in -joff -jon; do timeout 120 ./src/luajit $j tests/lib/ffrec-54.lua || exit 1; done
for j in -joff -jon; do timeout 120 ./src/luajit $j tests/lib/io-write-jit.lua || exit 1; done
for j in -joff -jon; do timeout 120 ./src/luajit $j tests/lib/env-noflush.lua || exit 1; done
# x64 math.random/negative-int-key JIT bug (known-bad math B): hangs on the
# buggy build, so bound it.
for j in -joff -O0 -O3; do timeout 120 ./src/luajit $j tests/lib/math-random-jit.lua || exit 1; done
# Array parts above 2^28 / 2^29 slots: 64 bit index scaling in the interpreter
# and in compiled code. Needs about 4.3 GiB, skips itself on a small machine.
for j in -joff -jon; do timeout 600 ./src/luajit $j tests/lib/array-huge.lua || exit 1; done

say "harness: GC stress (pause 0 in every arm), int64 + close tests, modes A+B+R"
stage 'tail -12' tests/harness.sh --strict --mode all --opt-levels 0,3 --gc-stress --corpus tests/d54 \
  --filter 'i64_' --filter 'close_' --filter 'coro_' --filter 'gc_' --filter 'bits_' --timeout 300

say "JIT tooling smoke (-jv/-jdump/-jbc/-jp over the int64 tests)"
stage 'tail -4' sh tests/jitutil-smoke.sh

say "real-program corpus (tests/corpus-ext: PUC vs -joff / -jon / -jon+GC-stress)"
stage 'grep -v "^      " | tail -44' sh tests/corpus-ext/run.sh

say "C API"
stage "grep -E '^== (capi|i64|extraspace):'" tests/capi/run.sh

say "fuzz: mode B, 40 programs x opt levels 0-3, GC pressure"
stage 'tail -6' python3 tests/fuzz/fuzz.py --seed 1 --count 40 --mode B --opt-levels 0,1,2,3 --gc

say "done"
if [ -n "$FAILED" ]; then
  echo "ci-box: FAILED stages:$FAILED"
  exit 1
fi
echo "ci-box: all stages passed"
