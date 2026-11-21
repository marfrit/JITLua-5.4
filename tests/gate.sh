#!/bin/sh
# Tiered verification gate.
#
#   tests/gate.sh --tier quick|touch|full [--base <rev>] [--dry-run]
#                 [--remote "<box wrapper command>"] [--changed-file <file>]
#
#   quick  build + harness modes A and B on the d54 / corpus tests that are new
#          or changed against the base (a three-test smoke set when none is).
#          Run it after edits.
#   touch  quick + the stages the changed source files call for (table in
#          classify() below). Run it before each commit: --base HEAD.
#          A change to something the table does not know escalates to full.
#   full   the complete chain: tests/ci-box.sh, the sanitizer build and a strict
#          harness run over everything. Run it on both architectures before a
#          review and before a push.
#
# Base (quick, touch): --base <rev>, else $GATE_BASE, else the merge-base of HEAD
# and its upstream, else the commit the current branch was created from (oldest
# reflog entry), else HEAD~1. The diff is base against the working tree plus
# untracked files, so uncommitted edits count. --base HEAD means "only what is
# pending now".
#
# Tests in tests/gate-heavy.txt run only in the full tier (the harness gets them
# as --exclude).
#
# Boxes: a box copy of the tree has no .git. Give --remote (or $GATE_REMOTE) the
# command prefix that runs a command on a box from the current directory; the
# selection is made here and handed over in .gate-changed:
#   GATE_REMOTE="<box-wrapper> -t 3000" sh tests/gate.sh --tier touch --base HEAD
# Without --remote the gate runs in place.
#
# --dry-run prints the selected stages and test list and runs nothing.
# Exit status: 0 all selected stages passed (or nothing to run), 1 a stage
# failed, 2 usage error.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)

TIER=; BASE=${GATE_BASE:-}; DRY=0; REMOTE=${GATE_REMOTE:-}; CHANGED=
while [ $# -gt 0 ]; do
  case $1 in
    --tier) TIER=${2:-}; shift 2 || exit 2;;
    --base) BASE=${2:-}; shift 2 || exit 2;;
    --remote) REMOTE=${2:-}; shift 2 || exit 2;;
    --changed-file) CHANGED=${2:-}; shift 2 || exit 2;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "gate: unknown argument: $1" >&2; exit 2;;
  esac
done
case $TIER in quick|touch|full) ;; *) echo "gate: --tier quick|touch|full required" >&2; exit 2;; esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM

now() { date +%s; }

# ---------------------------------------------------------------- selection

# Heavy tests, as --exclude arguments.
EXCL=
if [ -f tests/gate-heavy.txt ]; then
  EXCL=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' tests/gate-heavy.txt | sed 's/^/--exclude /' | tr '\n' ' ')
fi
is_heavy() { grep -qx -- "$1" tests/gate-heavy.txt 2>/dev/null; }

# THE TABLE. One changed path -> the stage ids it calls for, or TEST (a corpus
# test, covered by quick), NONE (no code, nothing to run), FULL (unknown: run
# everything). Stage ids are defined at the bottom (ORDER). First match wins.
classify() {
  case $1 in
    docs/*|doc/*|*.md|COPYRIGHT|README.LuaJIT|.gitignore|.gitattributes|.github/*) echo NONE;;
    tests/gate-heavy.txt) echo NONE;;
    tests/d54/*.lua) echo TEST;;
    tests/corpus/puc54/libs/*|tests/corpus/puc54/packtests/*) echo modeA;;
    tests/corpus/puc54/*.lua) echo TEST;;
    tests/corpus/*|tests/ref/build-puc54-libs.sh|tests/ref/corpus-adapt.py) echo modeA;;
    # JIT: recorder, optimizer, assembler, trace machinery, VM assembly.
    # vm_*.dasc is also the interpreter, so it adds the runtime stages.
    src/vm_*.dasc) echo "modeA modeB assert jitsmoke gcstress";;
    src/lj_record*|src/lj_snap*|src/lj_opt_*|src/lj_asm*|src/lj_trace*|src/lj_ir*|src/lj_crecord*|src/lj_ffrecord*|src/lj_dispatch*|src/lj_mcode*|src/lj_target*|src/lj_emit_*)
      echo "modeB assert penlight jitsmoke";;
    src/jit/*|tests/jitutil-smoke.sh) echo jitsmoke;;
    # GC and tables
    src/lj_gc*|src/lj_tab*|src/lj_alloc*|tests/gcmode.*) echo "gcmode gcstress";;
    # parser / bytecode
    src/lj_parse*|src/lj_lex*|src/lj_bcdump*|src/lj_bcread*|src/lj_bcwrite*|src/lj_bc.*) echo "modeR parse";;
    # C API / FFI. lib_ffi.c is a library too.
    src/lib_ffi.c) echo "modeA capi";;
    src/lib_aux.c|src/lauxlib.h|src/lua.h|src/lua.hpp|src/lualib.h|src/luajit.h|src/lj_api*|src/lj_load*|src/lj_cconv*|src/lj_ccall*|src/lj_cdata*|src/lj_carith*|src/lj_cparse*|src/lj_ctype*|src/lj_clib*|src/lj_ccallback*|src/lj_cdef*|tests/capi/*)
      echo "modeA capi";;
    # libraries
    src/lib_*|src/lj_lib*) echo "modeA compat51";;
    # core runtime
    src/lj_meta*|src/lj_func*|src/lj_state*|src/lj_err*|src/lj_debug*|src/lj_str*|src/lj_buf*|src/lj_char*|src/lj_udata*|src/lj_vmmath*|src/lj_prng*|src/lj_vmevent*|src/lj_profile*)
      echo "modeA modeB modeR gcstress capi";;
    # harness and test infrastructure
    tests/lib/runner.py|tests/harness.sh|tests/known-*.tsv|tests/t-guarded.tsv|tests/lib/dump_reload.lua) echo "selftest modeA modeB modeR";;
    tests/lib/runner-selftest.sh) echo selftest;;
    tests/lib/assertbuild-d54.sh) echo assert;;
    tests/lib/compat51*) echo compat51;;
    tests/lib/*.lua) echo libchecks;;
    tests/nogc64-layout.sh) echo nogc64;;
    tests/corpus-ext/*) echo corpusext;;
    # Everything else: build files, headers such as lj_obj.h / lj_def.h /
    # lj_arch.h, src/host, the Makefiles, the gate scripts themselves.
    *) echo FULL;;
  esac
}

ORDER="build quick gcmode nogc64 selftest modeA modeB modeR parse assert compat51 libchecks gcstress jitsmoke penlight corpusext capi"

# ------------------------------------------------------------- changed files

list_changed() {  # prints "<status><TAB><path>" lines
  git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "gate: no git here; pass --changed-file or use --remote" >&2; exit 2; }
  if [ -z "$BASE" ]; then
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if [ -n "$up" ]; then
      BASE=$(git merge-base HEAD "$up")
    else
      br=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
      first=
      [ -n "$br" ] && first=$(git reflog show --format=%H "refs/heads/$br" 2>/dev/null | tail -n 1)
      if [ -n "$first" ]; then BASE=$(git merge-base HEAD "$first" 2>/dev/null || echo "$first")
      else BASE=$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD); fi
    fi
  fi
  git diff --no-renames --name-status "$BASE" --
  git ls-files -o --exclude-standard | grep -v '^\.gate-changed$' | sed 's/^/A\t/' || true
}

SEL=" "          # selected stage ids
TESTS=            # changed corpus tests (existing, not heavy)
SKIPPED=          # changed heavy tests (full only)
FULLWHY=          # first path that forced full
NCHG=0
EFF=$TIER

if [ "$TIER" != full ]; then
  CL=$TMP/changed
  if [ -n "$CHANGED" ]; then cat "$CHANGED" >"$CL"; BASEDESC="(from file)"; else list_changed >"$CL"; BASEDESC=$(git rev-parse --short "$BASE"); fi
  while IFS="$(printf '\t')" read -r st path; do
    [ -n "$path" ] || continue
    NCHG=$((NCHG + 1))
    cls=$(classify "$path")
    case $cls in
      NONE) ;;
      TEST)
        [ "$st" = D ] && continue
        if is_heavy "$path"; then SKIPPED="$SKIPPED $path"; else TESTS="$TESTS $path"; fi
        SEL="$SEL""quick ";;
      FULL) [ -n "$FULLWHY" ] || FULLWHY=$path;;
      *) [ "$TIER" = touch ] && for c in $cls; do SEL="$SEL$c "; done
         SEL="$SEL""quick ";;
    esac
  done <"$CL"
  if [ "$TIER" = touch ] && [ -n "$FULLWHY" ]; then EFF=full; fi
  if [ "$TIER" = quick ] && [ -n "$FULLWHY" ]; then SEL="$SEL""quick "; fi
  if [ "$EFF" != full ]; then
    case $SEL in *" quick "*) SEL="$SEL""build ";; esac
  fi
fi

# ------------------------------------------------------------------- remote

if [ -n "$REMOTE" ] && [ "$DRY" = 0 ]; then
  if [ "$TIER" = full ]; then
    # shellcheck disable=SC2086
    exec $REMOTE sh tests/gate.sh --tier full
  fi
  if [ "$EFF" != full ] && [ "$SEL" = " " ]; then
    echo "gate $TIER: only docs/non-code changes ($NCHG files vs $BASEDESC), nothing to run"
    exit 0
  fi
  cp "$CL" .gate-changed
  trap 'rm -rf "$TMP" .gate-changed' EXIT
  rc=0
  # shellcheck disable=SC2086
  $REMOTE sh tests/gate.sh --tier "$TIER" --changed-file .gate-changed || rc=$?
  exit $rc
fi

# ------------------------------------------------------------------- stages

H="tests/harness.sh --strict --timeout 120"
FAILED=
NRUN=0

s_build()    { make -j"$NPROC" && { tests/ref/bin/lua54ref -v >/dev/null 2>&1 || tests/ref/fetch-ref.sh --force; }; }
s_quick() {
  if [ -n "$TESTS" ]; then
    f=; for t in $TESTS; do f="$f --filter $t"; done
  else
    f="--filter tests/d54/numeric_01_types.lua --filter tests/d54/tbl_01_lib.lua --filter tests/d54/str_03_patterns.lua"
  fi
  # shellcheck disable=SC2086
  $H --mode both $f
}
s_gcmode()   { sh tests/gcmode.sh; }
s_nogc64()   { sh tests/nogc64-layout.sh; }
s_selftest() { sh tests/lib/runner-selftest.sh; }
# shellcheck disable=SC2086
s_modeA()    { $H --mode A $EXCL; }
# shellcheck disable=SC2086
s_modeB()    { $H --mode B --opt-levels 0,1,2,3 --corpus tests/d54 $EXCL; }
# shellcheck disable=SC2086
s_modeR()    { $H --mode R --corpus tests/d54 $EXCL; }
# shellcheck disable=SC2086
s_parse()    { $H --mode both --corpus tests/d54 --filter d54/parse_ --filter d54/lex_ --filter d54/load_ --filter d54/dump_ $EXCL; }
s_assert()   { HARNESS_EXTRA="$EXCL" sh tests/lib/assertbuild-d54.sh; }
s_compat51() { sh tests/lib/compat51build-d54.sh; }
s_libchecks() {
  for j in -joff -jon; do for t in bit-checkint ffrec-54 env-noflush; do
    timeout 120 ./src/luajit $j tests/lib/$t.lua || return 1; done; done
  for j in -joff -O0 -O3; do timeout 120 ./src/luajit $j tests/lib/math-random-jit.lua || return 1; done
}
s_gcstress() {
  $H --mode all --opt-levels 0,3 --gc-stress --corpus tests/d54 \
    --filter 'i64_' --filter 'close_' --filter 'coro_' --filter 'gc_' --filter 'bits_' --timeout 300
}
s_jitsmoke() { sh tests/jitutil-smoke.sh; }
s_penlight() { sh tests/corpus-ext/run.sh penlight; }
s_corpusext() { sh tests/corpus-ext/run.sh; }
s_capi()     { tests/capi/run.sh; }

desc_build="make + PUC reference"
desc_quick="harness A+B on changed tests"
desc_gcmode="GC policy modes"
desc_nogc64="x86_64 GC64 / non-GC64 layouts"
desc_selftest="harness self-test"
desc_modeA="strict harness mode A, whole corpus"
desc_modeB="strict mode B, opt levels 0-3, d54"
desc_modeR="strict mode R (dump/reload), d54"
desc_parse="parser/lexer/loader tests, modes A+B"
desc_assert="assert build, d54 mode B with -Ohotexit=1"
desc_compat51="5.1-compat build and checks"
desc_libchecks="tests/lib JIT checks"
desc_gcstress="GC stress, int64/close/coro/gc/bits, modes A+B+R"
desc_jitsmoke="JIT tooling smoke"
desc_penlight="corpus-ext: Penlight"
desc_corpusext="corpus-ext: all libraries"
desc_capi="C API tests"

counts_of() {  # compact harness summary from a stage log
  awk '/^  (PASS|FAIL|XFAIL|XPASS|BAD|TIMEOUT) +[0-9]/ { printf "%s %s ", $1, $2 }' "$1"
}

run_stage() {
  id=$1
  case $SEL in *" $id "*) ;; *) return 0;; esac
  eval "d=\$desc_$id"
  if [ "$DRY" = 1 ]; then
    printf '  %-10s %s\n' "$id" "$d"
    case $id in
      quick)
        if [ -n "$TESTS" ]; then for t in $TESTS; do echo "             test: $t"; done
        else echo "             (no changed corpus tests: smoke set numeric_01_types tbl_01_lib str_03_patterns)"; fi;;
      modeA) echo "             all of tests/d54 + tests/corpus/puc54 minus tests/gate-heavy.txt";;
      modeB|modeR|assert) echo "             all of tests/d54 minus tests/gate-heavy.txt";;
    esac
    return 0
  fi
  t0=$(now); rc=0
  "s_$id" >"$TMP/$id.log" 2>&1 || rc=$?
  t1=$(now); NRUN=$((NRUN + 1))
  c=$(counts_of "$TMP/$id.log")
  if [ "$rc" -eq 0 ]; then
    printf '[ ok ] %-10s %4ss  %s\n' "$id" "$((t1 - t0))" "$c"
  else
    printf '[FAIL] %-10s %4ss  rc=%s %s\n' "$id" "$((t1 - t0))" "$rc" "$c"
    tail -40 "$TMP/$id.log" | sed 's/^/       | /'
    FAILED="$FAILED $id"
  fi
}

verdict() {  # verdict <label> <seconds>
  if [ -n "$FAILED" ]; then
    echo "gate $1: FAIL ($2 s) failed stages:$FAILED"; exit 1
  fi
  echo "gate $1: PASS ($NRUN stages, $2 s)"; exit 0
}

# --------------------------------------------------------------------- full

# Exactly the chain that was run by hand before: ci-box, sanitizers, strict
# harness over everything, then the stage counts.
gate_full() {
  D=$TMP
  r1=0; sh tests/ci-box.sh > $D/cb.log 2>&1 || r1=$?
  r2=0; sh tests/ci-local.sh --sanitizers-only > $D/san.log 2>&1 || r2=$?
  r3=0; { make -j4 >/dev/null 2>&1 && tests/ref/fetch-ref.sh >/dev/null 2>&1 && tests/harness.sh --mode all --timeout 120 --strict; } > $D/strict.log 2>&1 || r3=$?
  echo "RC ci-box=$r1 san=$r2 strict=$r3"
  grep -E "all stages|ci-box:|ci-local:|PASS [0-9]+" $D/cb.log $D/san.log | tail -14 || true
  tail -4 $D/strict.log
  grep -E "^(FAIL|BAD|TIMEOUT|XPASS)" $D/strict.log $D/cb.log $D/san.log | head -20 || true
  echo "--- stage counts"; grep -E "^=== |^  (PASS|XFAIL|SKIP) +[0-9]|checks, " $D/cb.log | grep -v -E "^=== (machine|build|object|GC policy|harness self|lib checks|JIT tooling|real-program|done)" || true
  echo "--- asan"; grep -E "^  (PASS|XFAIL) +[0-9]" $D/san.log | head -2 || true
  echo "--- strict"; grep -E "^  (PASS|XFAIL|SKIP) +[0-9]" $D/strict.log || true
  grep -E "FAILED stages|unexpected diffs [1-9]" $D/cb.log 2>/dev/null | head -5 || true
  [ $((r1 + r2 + r3)) -eq 0 ] || FAILED=" ci-box=$r1 san=$r2 strict=$r3"
  NRUN=3
}

T0=$(now)
if [ "$EFF" = full ]; then
  if [ "$DRY" = 1 ]; then
    [ "$TIER" = full ] || echo "gate $TIER: escalates to full, $FULLWHY is not in the table"
    echo "gate full (dry run), runs in order:"
    echo "  sh tests/ci-box.sh                              (every ci-box stage, incl. fuzz and corpus-ext)"
    echo "  sh tests/ci-local.sh --sanitizers-only          (ASan/UBSan, assert-build C API)"
    echo "  make; tests/ref/fetch-ref.sh; tests/harness.sh --mode all --timeout 120 --strict"
    echo "  then the stage-count printout; heavy tests included"
    exit 0
  fi
  [ "$TIER" = full ] || echo "gate $TIER: escalating to full, $FULLWHY is not in the table"
  gate_full
  verdict full "$(( $(now) - T0 ))"
fi

if [ "$SEL" = " " ]; then
  echo "gate $TIER: only docs/non-code changes ($NCHG files vs $BASEDESC), nothing to run"
  exit 0
fi

[ "$DRY" = 1 ] && echo "gate $TIER (dry run) vs $BASEDESC: $NCHG changed files"
[ -z "$SKIPPED" ] || echo "heavy tests changed, left for the full tier:$SKIPPED"
for id in $ORDER; do
  run_stage "$id"
  # no point testing a tree that does not build
  case " $FAILED " in *" build "*) break;; esac
done
[ "$DRY" = 1 ] && { echo "gate $TIER (dry run): nothing executed"; exit 0; }
verdict "$TIER" "$(( $(now) - T0 ))"
