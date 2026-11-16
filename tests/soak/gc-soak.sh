#!/bin/sh
# Overnight GC soak: the GC-stress harness arms, the fuzzer (fresh seed per
# round, GC pressure) and the real-program corpus, in a loop for a number of
# hours. Logs only failures plus one summary line per round; prints a final
# summary. Exit status 1 if any round failed.
#
#   SOAK_HOURS=8 sh tests/soak/gc-soak.sh               # here (aarch64)
#   SOAK_HOURS=8 arm-box -t 32400 sh tests/soak/gc-soak.sh   # arm box
#   SOAK_HOURS=8 x64-box -t 32400 sh tests/soak/gc-soak.sh   # x64 box (serialized queue!)
#
# Knobs (environment): SOAK_HOURS (default 8), SOAK_NICE (nice level, default
# 19: the boxes share their host with other work), SOAK_JOBS (harness jobs,
# default 2 for the same reason), SOAK_SEED (first fuzz seed, default 1000),
# SOAK_LOG (failure details, default /tmp/gc-soak.log), SOAK_SECONDS (overrides
# SOAK_HOURS, for a smoke test). The box time limit (-t) must exceed the soak
# length by one round (~15 min): the round that is running at the deadline
# finishes.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
HOURS=${SOAK_HOURS:-8}
NICE=${SOAK_NICE:-19}
JOBS=${SOAK_JOBS:-2}
SEED=${SOAK_SEED:-1000}
LOG=${SOAK_LOG:-/tmp/gc-soak.log}
: > "$LOG"
say() { printf '%s\n' "$*"; }
now() { date +%s; }

say "== gc-soak: $(uname -m), $HOURS h, nice $NICE, jobs $JOBS, seed base $SEED, log $LOG =="
if [ ! -x src/luajit ]; then
  make -j"$(nproc 2>/dev/null || echo 4)" >"$LOG.build" 2>&1 || { tail -20 "$LOG.build"; exit 1; }
fi
if ! tests/ref/bin/lua54ref -v >/dev/null 2>&1; then
  rm -f tests/ref/bin/lua54ref tests/ref/bin/luac54ref
  tests/ref/fetch-ref.sh --force >"$LOG.ref" 2>&1 || { tail -20 "$LOG.ref"; exit 1; }
fi
src/luajit -v | head -1
tests/ref/bin/lua54ref -v | head -1

start=$(now)
deadline=$((start + ${SOAK_SECONDS:-$((HOURS * 3600))}))
round=0
nfail=0
failed_rounds=""
while [ "$(now)" -lt "$deadline" ]; do
  round=$((round + 1))
  r0=$(now)
  rfail=0
  seed=$((SEED + round))
  # 1. GC stress over the whole port corpus, modes A/B@0/B@3/R.
  out=$(nice -n "$NICE" tests/harness.sh --mode all --opt-levels 0,3 --gc-stress \
	--corpus tests/d54 --jobs "$JOBS" --timeout 600 2>&1)
  rc=$?
  h=$(printf '%s\n' "$out" | awk '/^  (PASS|FAIL|XFAIL|XPASS|TIMEOUT)/ {printf "%s%s ", $1, $2}')
  if [ $rc -ne 0 ]; then
    rfail=1
    { say "--- round $round harness (gc-stress, seed n/a) rc=$rc"; printf '%s\n' "$out" | grep -a -A12 '^FAIL\|^TIMEOUT\|^BAD'; } >>"$LOG"
  fi
  # 2. Fuzzer: a fresh seed every round, GC pressure, all opt levels.
  fout=$(nice -n "$NICE" python3 tests/fuzz/fuzz.py --seed "$seed" --count 60 --mode B \
	 --opt-levels 0,1,2,3 --gc --timeout 60 2>&1)
  frc=$?
  f=$(printf '%s\n' "$fout" | awk '/^  (pass|fail|invalid|timeout)/ {printf "%s%s ", $1, $2}')
  if [ $frc -ne 0 ]; then
    rfail=1
    { say "--- round $round fuzz seed $seed rc=$frc"; printf '%s\n' "$fout" | tail -40; } >>"$LOG"
  fi
  # 3. Real-program corpus (PUC vs -joff / -jon / -jon+GC-stress).
  cout=$(nice -n "$NICE" sh tests/corpus-ext/run.sh 2>&1)
  c=$(printf '%s\n' "$cout" | awk '/arms same/ {gsub(",", "", $3); print "corpus:" $3 "/" $6}')
  if printf '%s\n' "$cout" | grep -q 'unexpected diffs [1-9]'; then
    rfail=1
    { say "--- round $round corpus-ext"; printf '%s\n' "$cout" | grep -a -v '^      ' | grep -a 'DIFF\|unexpected' | grep -a -v 'known:'; } >>"$LOG"
  fi
  dt=$(( $(now) - r0 ))
  say "round $round  ${dt}s  harness: ${h}fuzz(seed $seed): ${f}${c}  $( [ $rfail -eq 0 ] && echo ok || echo FAIL )"
  if [ $rfail -ne 0 ]; then nfail=$((nfail + 1)); failed_rounds="$failed_rounds $round"; fi
done
say "== gc-soak summary: $round rounds in $(( ($(now) - start) / 60 )) min, failed rounds: $nfail${failed_rounds:+ (rounds$failed_rounds)} =="
if [ $nfail -ne 0 ]; then
  say "== failure details ($LOG) =="
  cat "$LOG"
  exit 1
fi
exit 0
