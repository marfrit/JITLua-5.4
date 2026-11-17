#!/bin/sh
# Build PUC-5.4 libs/*.so fixtures for tests/corpus/puc54/libs/.
#
# Called by fetch-ref.sh after the PUC tarball is extracted.
# Uses the PUC 5.4 headers from tests/ref/src/lua-$LUA_VERSION/.
#
#   build-puc54-libs.sh            # build libs from C sources in libs/
#
# No network needed — headers come from the already-extracted tarball.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$HERE/manifest.txt"

# Locate the PUC source tree (extracted by fetch-ref.sh into tests/ref/src/).
LUA_SRC="$HERE/src/lua-$LUA_VERSION"
if [ ! -d "$LUA_SRC" ]; then
  echo "build-puc54-libs: PUC source tree $LUA_SRC not found" >&2
  echo "(run fetch-ref.sh first to extract the tarball)" >&2
  exit 1
fi

LUA_DIR="$LUA_SRC"

# Detect available compiler
if command -v gcc >/dev/null 2>&1; then
  CC=gcc
elif command -v clang >/dev/null 2>&1; then
  CC=clang
else
  echo "build-puc54-libs: no C compiler found" >&2
  exit 1
fi

CFLAGS="-Wall -std=gnu99 -O2 -I$LUA_DIR -fPIC -shared"

LIBS_DIR="$ROOT/tests/corpus/puc54/libs"

for src in lib1 lib11 lib2 lib21; do
  srcfile="$LIBS_DIR/${src}.c"
  out="$LIBS_DIR/${src}.so"
  if [ ! -f "$srcfile" ]; then
    echo "build-puc54-libs: source $srcfile not found" >&2
    exit 1
  fi
  $CC $CFLAGS -o "$out" "$srcfile"
  echo "built $out"
done

# lib2-v2.so is compiled from lib22.c (same as lib2 but with id() returning bool)
srcfile="$LIBS_DIR/lib22.c"
out="$LIBS_DIR/lib2-v2.so"
$CC $CFLAGS -o "$out" "$srcfile"
echo "built $out"

echo "puc54 libs ready"
