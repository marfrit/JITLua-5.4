#!/bin/sh
# Real-program corpus: well-known Lua libraries with their own test suites,
# run under PUC-Lua 5.4.7 and under ours (-joff, -jon, -jon with the GC on
# every allocation), outputs and exit codes compared per arm. The C modules
# (LPeg, lua-cjson, LuaFileSystem) are built twice from the pinned sources,
# against PUC's headers for the PUC arm and against ours for the other three
# (tests/ref/src/lua-5.4.7/src is left behind by fetch-ref.sh). LFS also
# unlocks Penlight's five LFS-dependent scripts.
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
CC=${CC:-cc}
PUCINC=$ROOT/tests/ref/src/lua-5.4.7/src
MOD=$OUT/cmod
mkdir -p "$MOD/puc" "$MOD/ours"
CPATH_PUC=; CPATH_OURS=

# Normalise output: addresses, timings, scratch paths, and the program-name
# prefix in error messages. Traceback C frames ("[C]: in ?") and the package
# "no file" list are NOT normalized: both now match PUC (5.4 traceback wording
# and the PUC setpath ";;" expansion).
norm() {
  sed -e 's/0x[0-9a-fA-F]\{6,\}/0xADDR/g' \
      -e 's/^Lua 5\.4\.[0-9]*  Copyright (C) .*$/VERSION-BANNER/' \
      -e 's/^LuaJIT 2\.1\.[A-Za-z0-9]* -- Copyright (C) .*$/VERSION-BANNER/' \
      -e 's/[0-9]\+\.[0-9]\+ *\(s\|ms\|sec\|seconds\)\b/T/g' \
      -e 's/[0-9]\+\.[0-9]\+\(e[-+]\?[0-9]\+\)\?s\b/T/g' \
      -e "s#$OUT#OUT#g" -e "s#$ROOT#ROOT#g" \
      -e 's#^ROOT/tests/ref/bin/lua54ref: #LUA: #' -e 's#^ROOT/src/luajit: #LUA: #' "$@"
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
    *.src.rock)  # a zip holding the release tarball; no unzip on the boxes
      python3 -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
n = [m for m in z.namelist() if m.endswith(".tar.gz")][0]
sys.stdout.buffer.write(z.read(n))' "$DL/$file" | tar xz -C "$OUT/$name" ;;
    *) tar xzf "$DL/$file" -C "$OUT/$name" ;;
  esac
  [ -d "$OUT/$name/$top" ] || { say "unexpected layout for $name"; return 1; }
  printf '%s' "$OUT/$name/$top"
}

# build_cmod NAME SONAME DIR CFLAGS SRCS...: compiles a C module from the
# extracted sources, once against PUC's headers into $MOD/puc and once
# against ours into $MOD/ours. Returns 1 (and counts an unexpected diff for
# ours) if a build fails; the suites then run without it.
build_cmod() {
  name=$1; so=$2; dir=$3; cflags=$4; shift 4
  for arm in puc ours; do
    if [ $arm = puc ]; then inc=$PUCINC; else inc=$ROOT/src; fi
    [ -f "$inc/lua.h" ] || { say "  $name: no headers at $inc"; return 1; }
    shim=""
    if [ $arm = ours ]; then  # see shim-ours.h: header gaps, reported, not hidden
      shim="-include $ROOT/tests/corpus-ext/shim-ours.h"
      say "  $name: built against our headers with shim-ours.h (C API gaps, see the header)"
    fi
    if ( cd "$dir" && $CC -O2 -shared -fPIC $cflags $shim -I"$inc" -o "$MOD/$arm/$so.so" "$@" ) > "$OUT/$name.build.$arm.txt" 2>&1; then
      :
    else
      say "  $name: build against $arm headers FAILED"
      sed 's/^/      /' "$OUT/$name.build.$arm.txt" | head -${DIFFLINES:-12}
      if [ $arm = ours ]; then ndiff=$((ndiff+1)); fail=1; fi
      return 1
    fi
  done
  CPATH_PUC="$MOD/puc/?.so;;"; CPATH_OURS="$MOD/ours/?.so;;"
  return 0
}

# run_suite NAME DIR LUA_PATH SCRIPTS...: runs each script under the four arms
# from DIR, concatenates "## script / rc / output" per arm, then compares.
# PRELUDE (optional, global) is Lua code run before each script under ours
# only, e.g. to make a suite that keys 5.1 semantics off jit.version take
# its Lua 5.4 branch. CPATH_PUC / CPATH_OURS (globals, set by build_cmod)
# are the LUA_CPATH for the PUC arm and for the three arms of ours.
PRELUDE=${PRELUDE:-}
run_suite() {
  name=$1; dir=$2; lpath=$3; shift 3
  for arm in puc joff jon gcs; do
    : > "$OUT/$name.$arm.txt"
    for s in "$@"; do
      pre=""; [ -n "$PRELUDE" ] && pre="-e $PRELUDE"
      # A wrapper script per arm carries the flags, so arg[-1] is an
      # interpreter path under every arm (Penlight's test-utils re-executes
      # it) -- the same shape as "lua script.lua" under PUC.
      case $arm in
        puc) cmd="$REF $s"; cpath=$CPATH_PUC ;;
        joff) printf '#!/bin/sh\nexec "%s" -joff %s "$@"\n' "$LUAJIT" "$pre" > "$OUT/lua-joff"; cmd="$OUT/lua-joff $s"; cpath=$CPATH_OURS ;;
        jon) printf '#!/bin/sh\nexec "%s" -jon %s "$@"\n' "$LUAJIT" "$pre" > "$OUT/lua-jon"; cmd="$OUT/lua-jon $s"; cpath=$CPATH_OURS ;;
        gcs) printf '#!/bin/sh\nexec "%s" -jon %s -e %s "$@"\n' "$LUAJIT" "$pre" "'collectgarbage(\"setpause\",0)'" > "$OUT/lua-gcs"; cmd="$OUT/lua-gcs $s"; cpath=$CPATH_OURS ;;
      esac
      chmod +x "$OUT"/lua-* 2>/dev/null
      ( cd "$dir" && LUA_PATH="$lpath" LUA_CPATH="${cpath:-;;}" timeout 600 $cmd ) > "$OUT/tmp.txt" 2>&1; rc=$?
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

# C modules first: LFS is needed by five of Penlight's scripts.
if want luafilesystem || want penlight; then
  d=$(extract luafilesystem) && build_cmod luafilesystem lfs "$d" "" src/lfs.c && {
    LFS_CPATH_PUC=$CPATH_PUC; LFS_CPATH_OURS=$CPATH_OURS
    if want luafilesystem; then
      run_suite luafilesystem "$d" ';;' tests/test.lua
    fi
  }
fi
if want lpeg; then
  d=$(extract lpeg) && build_cmod lpeg lpeg "$d" "-std=c99 -DNDEBUG" lpvm.c lpcap.c lptree.c lpcode.c lpprint.c lpcset.c && \
    run_suite lpeg "$d" './?.lua;;' test.lua
fi
if want lua-cjson; then
  d=$(extract lua-cjson) && build_cmod lua-cjson cjson "$d" "-DNDEBUG" lua_cjson.c strbuf.c fpconv.c && {
    # The UTF-8 round-trip fixture is generated by a perl script; without
    # perl the same test fails under every arm, which still compares equal.
    ( cd "$d/tests" && perl genutf8.pl ) > /dev/null 2>&1 || true
    run_suite lua-cjson "$d/tests" '../lua/?.lua;;' test.lua
  }
fi
CPATH_PUC=${LFS_CPATH_PUC:-}; CPATH_OURS=${LFS_CPATH_OURS:-}
if want penlight; then
  d=$(extract penlight) && {
    scripts=$(cd "$d" && ls tests/test-*.lua | tr '\n' ' ')
    run_suite penlight "$d" './lua/?.lua;./lua/?/init.lua;;' $scripts
  }
fi
CPATH_PUC=; CPATH_OURS=
if want serpent; then
  d=$(extract serpent) && run_suite serpent "$d" './src/?.lua;;' t/test.lua
fi
if want luaunit; then
  # luaunit keys its branches off jit.version when LuaJIT is present
  # (_LUAVERSION = jit and jit.version or _VERSION), so report our _VERSION
  # ("Lua 5.4") there and let it take its PUC 5.4 code paths.
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
