#!/bin/sh
# x64-box/arm-box are private wrappers that run a command on a remote x86_64/arm64 test host.
# Per-phase GC split (Stage 0b) runner for JITLua-5.4.  Measurement only.
#
# Builds the default tree (macro off) and runs the harness to prove default
# behaviour is unchanged, then builds a copy with -DLUAJIT_GC_STATS and reports
# the per-phase collector split for the selected workloads.
#
# One command per arch, on the box wrappers (private, not part of this repo):
#   x64-box -t 7200 sh tests/bench/gc-phase.sh
#   arm-box -t 7200 sh tests/bench/gc-phase.sh
#
# Knobs: GC_PHASE_ONLY=name[,name] (default the four Stage 0b workloads),
# GC_PHASE_REPS (default 3), GC_PHASE_HARNESS=0 to skip the A+B check,
# CC, CFLAGS.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
JOBS=${GC_JOBS:-$NPROC}
ARCH=$(uname -m)
LOG=${GC_BUILD_LOG:-/tmp/gc-phase-build.log}

say() { printf '\n=== %s ===\n' "$*"; }
load_line() { printf 'load: %s | luajit/make: %s\n' "$(uptime | sed 's/.*load average/load average/')" \
  "$(pgrep -a 'luajit|make|cc1' 2>/dev/null | head -5 | tr '\n' ';' || true)"; }

say "machine: $ARCH, nproc $NPROC, jobs $JOBS"
load_line
if [ "$ARCH" = "aarch64" ] && [ "${GC_ALLOW_LOAD:-0}" != 1 ]; then
  if pgrep -a 'luajit|make' >/dev/null 2>&1; then
    echo "other luajit/make jobs are running on this box; set GC_ALLOW_LOAD=1 to override" >&2
    exit 2
  fi
fi

# -- default build: the macro off must change nothing ---------------------

if [ "${GC_PHASE_HARNESS:-1}" = 1 ]; then
  say "build: default (macro off)"
  make -j"$JOBS" >"$LOG.ours" 2>&1 || { tail -30 "$LOG.ours"; exit 1; }
  src/luajit -v | head -1
  say "build: PUC-Lua 5.4.9 reference (harness mode A)"
  tests/ref/fetch-ref.sh >"$LOG.ref" 2>&1 || { tail -30 "$LOG.ref"; exit 1; }
  tests/ref/bin/lua54ref -v | head -1
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

# -- instrumentation build: a copy, so the default objects are not rebuilt -

say "build: LUAJIT_GC_STATS (per-phase split)"
rm -rf tmp/gcstats
mkdir -p tmp/gcstats
cp -a Makefile src dynasm tmp/gcstats/
( cd tmp/gcstats && make clean >/dev/null 2>&1; make -j"$JOBS" CFLAGS="-DLUAJIT_GC_STATS" >"$LOG.stats" 2>&1 ) || {
  tail -30 "$LOG.stats"; exit 1; }
[ -x tmp/gcstats/src/luajit ] || { echo "no tmp/gcstats/src/luajit" >&2; exit 1; }
tmp/gcstats/src/luajit -v | head -1

say "measure: per-phase split"
GC_MOD_FAMILIES=${GC_MOD_FAMILIES:-ours} python3 tests/bench/gc-phase.py
rc=$?
say "done (rc=$rc)"
load_line
exit $rc
