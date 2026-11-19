#!/bin/sh
# Build the C fixtures that tests/corpus/puc54 loads, once per arm.
#
#   puc  variant: compiled against PUC 5.4.9's public headers
#   jit  variant: compiled against JITLua-5.4's public headers (src/)
#
# The harness gives each arm its own LUA_CPATH and its own copy of libs/ in
# the scratch tree, so a fixture is never loaded by both interpreters: a
# PUC-built module is now rejected by luaL_checkversion at open (ABI stamp).
#
# Called by fetch-ref.sh (after extracting the PUC tree, so headers exist) and
# by tests/harness.sh (so a plain harness run has fixtures without a fetch).
# Only fixtures whose .so is missing or older than a source/header rebuild.
#
#   build-puc54-libs.sh              # both arms
#   CORPUS_LIBS_OUT=/tmp/x ...      # other output root
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$HERE/manifest.txt"

LUA_DIR="$HERE/src/lua-$LUA_VERSION/src"
SRC="$ROOT/src"
OUT=${CORPUS_LIBS_OUT:-$ROOT/tests/capi/build/corpus-libs}

if command -v gcc >/dev/null 2>&1; then
  CC=gcc
elif command -v clang >/dev/null 2>&1; then
  CC=clang
else
  echo "build-puc54-libs: no C compiler found" >&2
  exit 1
fi
CFLAGS="-Wall -std=gnu99 -O2 -fPIC -shared"

needs_build() { # needs_build <incdir> <out.so> <src.c>
  [ -f "$2" ] || return 0
  [ "$3" -nt "$2" ] && return 0
  for h in lua.h luaconf.h lauxlib.h; do
    [ -e "$1/$h" ] && [ "$1/$h" -nt "$2" ] && return 0
  done
  return 1
}

build_arm() { # build_arm <arm> <incdir>
  arm=$1; inc=$2
  [ -f "$inc/lua.h" ] && [ -f "$inc/lauxlib.h" ] || return 1
  mkdir -p "$OUT/$arm"
  for entry in lib1:lib1 lib11:lib11 lib2:lib2 lib21:lib21 lib2-v2:lib22; do
    name=${entry%%:*}; src=${entry#*:}
    srcfile="$ROOT/tests/corpus/puc54/libs/$src.c"
    out="$OUT/$arm/$name.so"
    if needs_build "$inc" "$out" "$srcfile"; then
      tmp="$out.tmp.$$"
      $CC $CFLAGS -I"$inc" -o "$tmp" "$srcfile"
      mv -f "$tmp" "$out"
    fi
  done
  echo "corpus libs ($arm): $OUT/$arm"
}

build_arm jit "$SRC"
if [ -d "$LUA_DIR" ]; then
  build_arm puc "$LUA_DIR"
else
  echo "build-puc54-libs: no PUC source at $LUA_DIR; puc fixtures not built" >&2
  echo "(run fetch-ref.sh first; mode A needs them)" >&2
fi
