#!/bin/sh
# x64-box/arm-box are private wrappers that run a command on a remote x86_64/arm64 test host.
# GC baseline runner for JITLua-5.4.  Measurement only: no GC behaviour change
# in a default build (the optional LUAJIT_GC_STATS block is compiled out).
#
# One command per arch, on the box wrappers (private, not part of this repo):
#   x64-box -t 7200 sh tests/bench/gc-measure.sh
#   arm-box -t 7200 sh tests/bench/gc-measure.sh
#
# Knobs (environment): GC_ONLY=name[,name] (classic or corpus names),
# GC_CLASSIC=0, GC_CORPUS=0, GC_REPS_MAX (default 5), CC, CFLAGS.
# The script prints machine/load, build status, every per-workload table and a
# final SUMMARY json line; stdout is the only channel back from a box job.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
JOBS=${GC_JOBS:-$NPROC}
ARCH=$(uname -m)
LOG=${GC_BUILD_LOG:-/tmp/gc-measure-build.log}

say() { printf '\n=== %s ===\n' "$*"; }
load_line() { printf 'load: %s | luajit/make: %s\n' "$(uptime | sed 's/.*load average/load average/')" \
  "$(pgrep -a 'luajit|make|cc1' 2>/dev/null | head -5 | tr '\n' ';' || true)"; }

say "machine: $ARCH, nproc $NPROC, jobs $JOBS"
load_line
# The arm64 test host is shared: refuse to measure while another luajit/make
# job is running there, unless the caller explicitly overrides.
if [ "$ARCH" = "aarch64" ] && [ "${GC_ALLOW_LOAD:-0}" != 1 ]; then
  if pgrep -a 'luajit|make' >/dev/null 2>&1; then
    echo "other luajit/make jobs are running on this box; set GC_ALLOW_LOAD=1 to override" >&2
    exit 2
  fi
fi

# -- builds ---------------------------------------------------------------

say "build: ours (default GC)"
make -j"$JOBS" >"$LOG.ours" 2>&1 || { tail -30 "$LOG.ours"; exit 1; }
src/luajit -v | head -1

# Optional stats build: a copy of src+dynasm so the default objects are not
# rebuilt, compiled with -DLUAJIT_GC_STATS (CFLAGS, never XCFLAGS).
say "build: ours with LUAJIT_GC_STATS"
rm -rf tmp/gcstats
mkdir -p tmp/gcstats
cp -a Makefile src dynasm tmp/gcstats/
( cd tmp/gcstats && make clean >/dev/null 2>&1; make -j"$JOBS" CFLAGS="-DLUAJIT_GC_STATS" >"$LOG.stats" 2>&1 ) || {
  tail -30 "$LOG.stats"; exit 1; }

say "build: stock LuaJIT 2.1 (pinned yardstick)"
STOCK_TAR="$ROOT/.dlcache/bench/luajit-63c8f1a9.tar.gz"
[ -f "$STOCK_TAR" ] || { echo "missing $STOCK_TAR (run on a networked host first)" >&2; exit 1; }
if [ ! -x tmp/stock-luajit/src/luajit ]; then
  rm -rf tmp/stock-luajit; mkdir -p tmp/stock-luajit
  tar xzf "$STOCK_TAR" -C tmp/stock-luajit --strip-components=1
  ( cd tmp/stock-luajit && make -j"$JOBS" >"$LOG.stock" 2>&1 ) || {
    tail -30 "$LOG.stock"; exit 1; }
fi
tmp/stock-luajit/src/luajit -v | head -1

say "build: PUC-Lua 5.4.9 reference"
tests/ref/fetch-ref.sh >"$LOG.ref" 2>&1 || { tail -30 "$LOG.ref"; exit 1; }
tests/ref/bin/lua54ref -v | head -1

# Instrumented copy of the reference, counters only; never patches tests/ref.
say "build: PUC-Lua 5.4.9 with LUA_GC_STATS"
rm -rf tmp/puc-stats
mkdir -p tmp/puc-stats
cp -a tests/ref/src/lua-5.4.9/. tmp/puc-stats/
python3 tests/bench/puc_gc_stats.py tmp/puc-stats || { echo "PUC stats patch failed" >&2; exit 1; }
( cd tmp/puc-stats && make clean >/dev/null 2>&1; \
  make linux MYCFLAGS="-DLUA_GC_STATS" >"$LOG.pucstats" 2>&1 ) || {
  tail -30 "$LOG.pucstats"; exit 1; }
[ -x tmp/puc-stats/src/lua ] || { echo "no tmp/puc-stats/src/lua" >&2; exit 1; }

# Default-build behaviour must be unchanged: the full harness in modes A+B
# (the macro is off in src/luajit above).  Set GC_HARNESS=0 to skip locally.
if [ "${GC_HARNESS:-1}" = 1 ]; then
  say "harness: modes A+B on the default build (macro off)"
  hout=$(tests/harness.sh 2>&1) || hrc=$?
  hrc=${hrc:-0}
  printf '%s\n' "$hout" | awk '/^  (PASS|FAIL|XFAIL|XPASS|TIMEOUT)/ {c[$1]+=$2} END {for (k in c) printf "  %s %d\n", k, c[k]}'
  if [ "$hrc" -ne 0 ]; then
    printf '%s\n' "$hout" | grep -a -A12 '^FAIL\|^TIMEOUT\|^BAD' | head -60
    echo "harness failed (rc=$hrc)" >&2
    exit 1
  fi
fi

# -- measurement ----------------------------------------------------------

say "measure: classic + corpus-ext, arms interleaved"
python3 tests/bench/gc_measure.py
rc=$?
say "done (rc=$rc)"
load_line
exit $rc
