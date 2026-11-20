#!/bin/sh
# Self-test of the harness's known-bad / known-different handling
# (tests/lib/runner.py). Builds a four-file corpus under tests/report and
# checks, in mode A against the reference interpreter:
#   - a known difference is an XFAIL, listed under "known differences";
#   - an entry that passes is an XPASS in either file, fatal with --strict;
#   - a failure in a mode the difference entry does not name is a FAIL, and
#     --update-known-bad writes it to known-bad.tsv, not into nowhere;
#   - a job listed in both files is reported as the defect;
#   - --update-known-bad never copies a difference into known-bad.tsv;
#   - the t-guarded table decides per vendored puc54 file whether it runs with
#     the internal test library T undefined in both arms or stays a SKIP.
# Needs src/luajit and tests/ref/bin/lua54ref (tests/ref/fetch-ref.sh).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
W="$ROOT/tests/report/runner-selftest"
REL=tests/report/runner-selftest/corpus
rm -rf "$W"
mkdir -p "$W/corpus"
trap 'rm -rf "$W"' EXIT INT TERM

DIFF='print(rawget(_G, "jit") and "fork" or "reference")'
echo 'print("same")' >"$W/corpus/same.lua"
echo "$DIFF" >"$W/corpus/different.lua"
echo "$DIFF" >"$W/corpus/othermode.lua"
echo "$DIFF" >"$W/corpus/both.lua"
echo 'print("same")' >"$W/corpus/stale.lua"
printf '%s\tA\tdefect reason\n' "$REL/both.lua" >"$W/kb.tsv"
{
  printf '%s\tA\tdifference reason\n' "$REL/different.lua"
  printf '%s\tR\tdifference in another mode\n' "$REL/othermode.lua"
  printf '%s\tA\tdifference reason for a listed defect\n' "$REL/both.lua"
  printf '%s\tA\tstale difference\n' "$REL/stale.lua"
} >"$W/kd.tsv"

TAB=$(printf '\t')
fails=0
check() { # check <label> <command...>
  _l=$1; shift
  if "$@"; then echo "ok   $_l"; else echo "FAIL $_l"; fails=$((fails + 1)); fi
}
harness() {
  sh "$ROOT/tests/harness.sh" --mode A --corpus "$REL" --known-bad "$W/kb.tsv" \
    --known-different "$W/kd.tsv" --report-dir "$W/report" "$@"
}

rc=0; harness >"$W/out1" 2>&1 || rc=$?
check "an unlisted failure fails the run" [ "$rc" -eq 1 ]
check "one PASS, one FAIL, two XFAIL, one XPASS" sh -c \
  "grep -q '^  PASS   1\$' '$W/out1' && grep -q '^  FAIL   1\$' '$W/out1' &&
   grep -q '^  XFAIL  2\$' '$W/out1' && grep -q '^  XPASS  1\$' '$W/out1'"
check "the failure is the test whose difference entry names another mode" \
  grep -q "^FAIL  A   $REL/othermode.lua" "$W/out1"
check "a difference is listed under known differences" sh -c \
  "sed -n '/known differences/,/now passing/p' '$W/report/last.md' | grep -q 'different.lua.*KNOWN DIFFERENCE: difference reason'"
check "a job in both files is listed as the defect" sh -c \
  "sed -n '/known defects/,/known differences/p' '$W/report/last.md' | grep -q 'both.lua.*defect reason'"
check "the stale difference is an XPASS that names its file" sh -c \
  "sed -n '/now passing/,/skipped/p' '$W/report/last.md' | grep -q 'stale.lua.*known-different.tsv'"

rm -f "$W/corpus/othermode.lua"
rc=0; harness >"$W/out2" 2>&1 || rc=$?
check "XPASS alone does not fail a normal run" [ "$rc" -eq 0 ]
rc=0; harness --strict >"$W/out3" 2>&1 || rc=$?
check "--strict makes the XPASS of a difference entry fatal" [ "$rc" -eq 1 ]

echo "$DIFF" >"$W/corpus/othermode.lua"
rc=0; harness --update-known-bad >"$W/out4" 2>&1 || rc=$?
check "--update-known-bad records the failure in the other mode" \
  grep -q "^$REL/othermode.lua${TAB}A${TAB}" "$W/kb.tsv"
check "--update-known-bad keeps the defect and its reason" \
  grep -q "^$REL/both.lua${TAB}A${TAB}defect reason\$" "$W/kb.tsv"
check "--update-known-bad does not copy a difference" sh -c \
  "! grep -q 'different.lua' '$W/kb.tsv' && ! grep -q 'KNOWN DIFFERENCE' '$W/kb.tsv'"
rc=0; harness --strict >"$W/out5" 2>&1 || rc=$?
check "after the update only the stale entry is left to fix" sh -c \
  "[ $rc -eq 1 ] && grep -q '^  FAIL   0\$' '$W/out5' && grep -q '^  XPASS  1\$' '$W/out5'"

# The t-guarded table (tests/t-guarded.tsv): a vendored puc54 file that mentions
# T runs when its row says "run" and stays a documented SKIP otherwise. The file
# content is the same in all three cases -- T is undefined in both arms, so the
# `T and ...` line is dead weight and both arms print the same thing.
TG="$W/corpus/puc54"
TGREL=tests/report/runner-selftest/corpus/puc54
mkdir -p "$TG"
TFILE='local color = T and T.gccolor
print("same")'
printf '%s\n' "$TFILE" >"$TG/tguarded.lua"
cp "$TG/tguarded.lua" "$TG/tunlisted.lua"
cp "$TG/tguarded.lua" "$TG/tskip.lua"
{
  printf '%s\trun\tT-guarded, runs in both arms\n' "$TGREL/tguarded.lua"
  printf '%s\tskip\tunguarded T use in this corpus\n' "$TGREL/tskip.lua"
} >"$W/tg.tsv"
tgharness() {
  sh "$ROOT/tests/harness.sh" --mode A --corpus "$TGREL" --t-guarded "$W/tg.tsv" \
    --report-dir "$W/report-tg" "$@"
}
rc=0; tgharness >"$W/out6" 2>&1 || rc=$?
check "a t-guarded run entry is not skipped and passes" sh -c \
  "[ $rc -eq 0 ] && grep -q '^  PASS   1\$' '$W/out6' && grep -q '^  SKIP   2\$' '$W/out6' &&
   grep -q '^  FAIL   0\$' '$W/out6'"
check "the unlisted file is a documented SKIP with the default reason" sh -c \
  "grep -q 'tunlisted.lua.*not triaged yet' '$W/report-tg/last.md'"
check "a skip row keeps the file skipped with its own reason" sh -c \
  "grep -q 'tskip.lua.*unguarded T use in this corpus' '$W/report-tg/last.md'"
rc=0; tgharness --t-guarded /dev/null >"$W/out7" 2>&1 || rc=$?
check "without the table every T file stays skipped" sh -c \
  "[ $rc -eq 0 ] && grep -q '^  PASS   0\$' '$W/out7' && grep -q '^  SKIP   3\$' '$W/out7'"

if [ "$fails" -ne 0 ]; then
  echo "runner-selftest: FAILED ($fails)"
  for f in "$W"/out*; do echo "--- $f"; cat "$f"; done
  exit 1
fi
echo "runner-selftest: OK"
