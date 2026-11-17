#!/bin/sh
# Benchmark gate for ADR-001b: boxing versus 16-byte.
# arm64-build/x64-build are private remote build wrappers: they copy the tree,
# run the command there and return stdout. They are not part of this repository.
#
# Four arms, all inside ONE box job (same machine, same moment):
#   1  our build, JIT on
#   2  our build, -joff
#   3  stock LuaJIT 2.1 snapshot (pinned in .dlcache/bench) with FFI uint64_t
#   4  PUC-Lua 5.4.9 (tests/ref/bin/lua54ref)
# Each benchmark runs 3x per arm; the runner reports the MEDIAN wall time.
# the arm64 build box shares its CPU with model serving: differences under ~10 % are noise.
#
#   arm64-build -t 1800 sh tests/bench/run.sh
#   sh tests/bench/run.sh               # on a normal machine
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
STOCK=tmp/stock-luajit
STOCK_TAR="$ROOT/.dlcache/bench/luajit-63c8f1a9.tar.gz"
REPS=${BENCH_REPS:-3}

say() { printf '\n=== %s ===\n' "$*"; }

say "build: ours"
make -j"$NPROC" >/tmp/bench-ours.log 2>&1 || { tail -20 /tmp/bench-ours.log; exit 1; }
./src/luajit -joff -e 'print("num model: " .. tostring(math.type(3)))'

say "build: reference PUC 5.4.9"
[ -x tests/ref/bin/lua54ref ] || tests/ref/fetch-ref.sh >/tmp/bench-ref.log 2>&1 || {
  tail -20 /tmp/bench-ref.log; exit 1; }

say "build: stock LuaJIT 2.1 (FFI yardstick)"
if [ ! -f "$STOCK_TAR" ]; then
  echo "missing $STOCK_TAR; run tests/bench/classic/fetch.sh on a networked host" >&2
  exit 1
fi
if [ ! -x "$STOCK/src/luajit" ]; then
  rm -rf "$STOCK"; mkdir -p "$STOCK"
  tar xzf "$STOCK_TAR" -C "$STOCK" --strip-components=1
  ( cd "$STOCK" && make -j"$NPROC" >/tmp/bench-stock.log 2>&1 ) || {
    tail -20 /tmp/bench-stock.log; exit 1; }
fi
"$STOCK/src/luajit" -v | head -1

median() { # read numbers on stdin, print the median
  sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'
}

run_arm() { # label, command prefix...
  label=$1; shift
  printf '\narm %s\n' "$label"
  for b in b1_fnv b2_table64 b2b_ms64 b3_int32; do
    vals=""
    i=0
    rest=""
    while [ $i -lt "$REPS" ]; do
      out=$("$@" "tests/bench/$b.lua" 2>&1) || { echo "  $b FAILED: $out"; break; }
      ms=$(printf '%s\n' "$out" | awk '{print $2}')
      vals="$vals$ms
"
      rest=$(printf '%s\n' "$out" | cut -d' ' -f3-)
      i=$((i+1))
    done
    m=$(printf '%s' "$vals" | grep -v '^$' | median)
    printf '  %-10s median %8s ms   last: %s\n' "$b" "${m:-n/a}" "${rest:-}"
  done
}

run_arm "1 ours JIT on" ./src/luajit -jon
run_arm "2 ours -joff" ./src/luajit -joff
run_arm "3 stock 2.1 FFI" env BENCH_FFI=1 "$STOCK/src/luajit" -jon
run_arm "4 PUC 5.4.9" tests/ref/bin/lua54ref

say "done"
