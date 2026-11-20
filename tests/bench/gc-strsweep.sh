#!/bin/sh
# A/B runner for the string-sweep prefetch (gc_sweepstr).  Measurement only.
#
# Builds the same tree twice -- base with -DLJ_STR_PREFETCH=0 (the prefetch is
# preprocessed out, i.e. the unmodified collector) and head with the default
# distance -- then runs the two arms interleaved in one job on one box.
#
# Use one box for both arms, ideally in one job:
#   X64_BOX_HOST=<box> x64-box -t 7200 sh tests/bench/gc-strsweep.sh
#   arm-box -t 7200 sh tests/bench/gc-strsweep.sh
#
# Knobs: GC_AB_ONLY=name[,name], GC_REPS_FORCE, GC_AB_PAIRS, GC_AB_PAIR_WORK,
# CC, CFLAGS.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
JOBS=${GC_JOBS:-$NPROC}
ARCH=$(uname -m)
LOG=${GC_BUILD_LOG:-/tmp/gc-strsweep-build.log}

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

build() {  # <dir> <extra-cflags>
  rm -rf "$1"
  mkdir -p "$1"
  cp -a Makefile src dynasm "$1/"
  _log="$ROOT/$1.log"
  ( cd "$1" && make clean >/dev/null 2>&1; make -j"$JOBS" CFLAGS="$2" >"$_log" 2>&1 ) || {
    tail -30 "$_log"; exit 1; }
  [ -x "$1/src/luajit" ] || { echo "no $1/src/luajit" >&2; exit 1; }
  "$1/src/luajit" -v | head -1
}

say "build: base (-DLJ_STR_PREFETCH=0, prefetch preprocessed out)"
build tmp/gc-alt-base "-DLJ_STR_PREFETCH=0"
say "build: head (default LJ_STR_PREFETCH)"
build tmp/gc-alt-head ""

say "measure: base vs head, interleaved"
GC_MOD_FAMILIES=${GC_MOD_FAMILIES:-ours} python3 tests/bench/gc-strsweep.py
rc=$?
say "done (rc=$rc)"
load_line
exit $rc
