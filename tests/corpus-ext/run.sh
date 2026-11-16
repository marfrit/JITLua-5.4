#!/bin/sh
# Real-program corpus: well-known pure-Lua libraries with their own test
# suites, run under PUC-Lua 5.4.7 and under ours (-joff, -jon, -jon with the
# GC on every allocation), outputs and exit codes compared per arm.
#
# The release archives live in .dlcache/ (downloaded once on a machine with
# network, pinned by sha256 in manifest.tsv); the boxes have no network.
#
#   sh tests/corpus-ext/run.sh            # all libraries
#   sh tests/corpus-ext/run.sh serpent    # one
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
LUAJIT=${LUAJIT:-$ROOT/src/luajit}
REF=${REF:-$ROOT/tests/ref/bin/lua54ref}
OUT=${CORPUS_EXT_OUT:-/tmp/corpus-ext}
DL=$ROOT/.dlcache
ONLY=${1:-}
rm -rf "$OUT"; mkdir -p "$OUT"

fail=0; ndiff=0; nsame=0
say() { printf '%s\n' "$*"; }

# Normalise output: addresses, timings, scratch paths, and the cosmetic
# differences between the two interpreters (program name in error messages,
# "[C]: in ?" vs "[C]: at 0x...", the "no file ''" line our package.path
# expansion adds -- reported separately, not a library finding).
norm() {
  sed -e 's/0x[0-9a-fA-F]\{6,\}/0xADDR/g' \
      -e 's/[0-9]\+\.[0-9]\+ *\(s\|ms\|sec\|seconds\)\b/T/g' \
      -e 's/[0-9]\+\.[0-9]\+\(e[-+]\?[0-9]\+\)\?s\b/T/g' \
      -e "s#$OUT#OUT#g" -e "s#$ROOT#ROOT#g" \
      -e 's#^ROOT/tests/ref/bin/lua54ref: #LUA: #' -e 's#^ROOT/src/luajit: #LUA: #' \
      -e 's#\[C\]: at 0xADDR#[C]: in ?#' \
      -e "/^	no file ''\$/d" "$@"
}

# extract NAME: verify the archive and unpack it into $OUT/NAME/<topdir>.
extract() {
  name=$1
  line=$(grep "^$name	" tests/corpus-ext/manifest.tsv) || { say "no manifest entry: $name"; return 1; }
  file=$(printf '%s' "$line" | cut -f2); sum=$(printf '%s' "$line" | cut -f3)
  top=$(printf '%s' "$line" | cut -f4)
  [ -s "$DL/$file" ] || { say "missing $DL/$file (download it on a networked machine)"; return 1; }
  have=$(sha256sum "$DL/$file" | cut -d' ' -f1)
  [ "$have" = "$sum" ] || { say "sha256 mismatch for $file: $have"; return 1; }
  mkdir -p "$OUT/$name"
  case "$file" in
    *.src.rock) unzip -p "$DL/$file" '*.tar.gz' | tar xz -C "$OUT/$name" ;;
    *) tar xzf "$DL/$file" -C "$OUT/$name" ;;
  esac
  [ -d "$OUT/$name/$top" ] || { say "unexpected layout for $name"; return 1; }
  printf '%s' "$OUT/$name/$top"
}

# run_suite NAME DIR LUA_PATH SCRIPTS...: runs each script under the four arms
# from DIR, concatenates "## script / rc / output" per arm, then compares.
# PRELUDE (optional, global) is Lua code run before each script under ours
# only, e.g. to make a suite that keys 5.1 semantics off jit.version take
# its Lua 5.4 branch.
PRELUDE=${PRELUDE:-}
run_suite() {
  name=$1; dir=$2; lpath=$3; shift 3
  for arm in puc joff jon gcs; do
    : > "$OUT/$name.$arm.txt"
    for s in "$@"; do
      pre=""; [ -n "$PRELUDE" ] && pre="-e $PRELUDE"
      case $arm in
        puc) cmd="$REF $s" ;;
        joff) cmd="$LUAJIT -joff $pre $s" ;;
        jon) cmd="$LUAJIT -jon $pre $s" ;;
        gcs) cmd="$LUAJIT -jon $pre -e collectgarbage(\"setpause\",0) $s" ;;
      esac
      ( cd "$dir" && LUA_PATH="$lpath" timeout 600 $cmd ) > "$OUT/tmp.txt" 2>&1; rc=$?
      { printf '## %s rc=%s\n' "$s" "$rc"; cat "$OUT/tmp.txt"; } >> "$OUT/$name.$arm.txt"
    done
  done
  norm "$OUT/$name.puc.txt" > "$OUT/$name.puc.norm"
  for arm in joff jon gcs; do
    norm "$OUT/$name.$arm.txt" > "$OUT/$name.$arm.norm"
    if diff -q "$OUT/$name.puc.norm" "$OUT/$name.$arm.norm" >/dev/null; then
      say "  $name $arm: SAME"; nsame=$((nsame+1))
    else
      if grep -q "^$name	$arm	" tests/corpus-ext/known-diff.tsv 2>/dev/null; then
        say "  $name $arm: DIFF (known: $(grep "^$name	$arm	" tests/corpus-ext/known-diff.tsv | cut -f3))"
      else
        say "  $name $arm: DIFF"; ndiff=$((ndiff+1)); fail=1
      fi
      diff "$OUT/$name.puc.norm" "$OUT/$name.$arm.norm" | head -${DIFFLINES:-12} | sed 's/^/      /'
    fi
  done
  grep -c '^## ' "$OUT/$name.puc.txt" | sed "s/^/  $name: scripts /"
  grep '^## .*rc=[1-9]' "$OUT/$name.puc.txt" | sed 's/^## /  puc nonzero: /' | head -5
}

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

if want penlight; then
  d=$(extract penlight) && {
    scripts=$(cd "$d" && ls tests/test-*.lua | tr '\n' ' ')
    run_suite penlight "$d" './lua/?.lua;./lua/?/init.lua;;' $scripts
  }
fi
if want serpent; then
  d=$(extract serpent) && run_suite serpent "$d" './src/?.lua;;' t/test.lua
fi
if want luaunit; then
  # luaunit keys number/-0 semantics off jit.version ("LuaJIT" => 5.1 rules);
  # make it take its Lua 5.4 branch, which is what we implement.
  d=$(extract luaunit) && PRELUDE='jit.version=_VERSION' \
    run_suite luaunit "$d" './?.lua;;' run_unit_tests.lua
fi
if want rxi-json; then
  d=$(extract rxi-json) && run_suite rxi-json "$d/test" './?.lua;;' test.lua
fi
if want dkjson; then
  d=$(extract dkjson) && run_suite dkjson "$d" './?.lua;;' jsontest.lua
fi
# lua-MessagePack 0.5.4's suite needs lua-TestAssertion, which is not
# fetchable as a pinned archive right now (github/framagit/luarocks all 404
# on 2026-11-16); its rock stays in .dlcache for later.

say "== corpus-ext summary =="
say "  arms same $nsame, unexpected diffs $ndiff"
exit $fail
