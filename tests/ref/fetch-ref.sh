#!/bin/sh
# Fetch and build the PUC-Lua 5.4.9 reference interpreter used by harness mode A.
#
#   tests/ref/fetch-ref.sh            # download (cached), verify, build
#   tests/ref/fetch-ref.sh --force    # rebuild even if binaries exist
#   tests/ref/fetch-ref.sh --corpus   # also re-extract testes/ into tests/corpus/puc54
#
# Nothing here is committed except this script and manifest.txt: the tarballs,
# the source tree and the binaries are build artifacts (see .gitignore).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/luajit54-dl
. "$HERE/manifest.txt"

FORCE=0
CORPUS=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --corpus) CORPUS=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

mkdir -p "$CACHE" "$HERE/bin" "$HERE/src"
cd "$CACHE"

# Prefer the vendored tarball (tests/ref/dist): build boxes have no network.
if [ -f "$HERE/dist/$LUA_TARBALL" ]; then
  got=$(sha256sum "$HERE/dist/$LUA_TARBALL" | cut -d' ' -f1)
  if [ "$got" != "$LUA_SHA256" ]; then
    echo "CHECKSUM MISMATCH for vendored tests/ref/dist/$LUA_TARBALL" >&2
    exit 1
  fi
  cp "$HERE/dist/$LUA_TARBALL" "$LUA_TARBALL"
fi

fetch() { # url sha256 file
  if [ -f "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ]; then
    echo "cached: $3"
    return 0
  fi
  echo "fetch: $1"
  curl -fsSL --retry 3 -o "$3" "$1"
  got=$(sha256sum "$3" | cut -d' ' -f1)
  if [ "$got" != "$2" ]; then
    echo "CHECKSUM MISMATCH for $3" >&2
    echo "  expected $2" >&2
    echo "  got      $got" >&2
    exit 1
  fi
}

fetch_advisory() { # url sha256 file -- pin is the commit, not the tarball bytes
  if [ -f "$3" ]; then
    echo "cached: $3"
  else
    echo "fetch: $1"
    curl -fsSL --retry 3 -o "$3" "$1"
  fi
  got=$(sha256sum "$3" | cut -d' ' -f1)
  if [ "$got" != "$2" ]; then
    echo "warning: $3 checksum differs from manifest (GitHub regenerated the tarball?)" >&2
    echo "  expected $2 / got $got -- verify against commit $LUA_GH_COMMIT" >&2
  fi
}

fetch "$LUA_URL" "$LUA_SHA256" "$LUA_TARBALL"

if [ "$FORCE" = 1 ] || [ ! -x "$HERE/bin/lua54ref" ]; then
  rm -rf "$HERE/src/lua-$LUA_VERSION"
  tar xzf "$LUA_TARBALL" -C "$HERE/src"
  ( cd "$HERE/src/lua-$LUA_VERSION" && make linux -j"$(nproc 2>/dev/null || echo 4)" )
  cp "$HERE/src/lua-$LUA_VERSION/src/lua" "$HERE/bin/lua54ref"
  cp "$HERE/src/lua-$LUA_VERSION/src/luac" "$HERE/bin/luac54ref"
fi
"$HERE/bin/lua54ref" -v

if [ "$CORPUS" = 1 ]; then
  fetch_advisory "$LUA_GH_URL" "$LUA_GH_SHA256" "$LUA_GH_TARBALL"
  rm -rf "$CACHE/lua-$LUA_VERSION"
  tar xzf "$LUA_GH_TARBALL" -C "$CACHE"
  rm -rf "$ROOT/tests/corpus/puc54"
  cp -r "$CACHE/lua-$LUA_VERSION/testes" "$ROOT/tests/corpus/puc54"
  python3 "$ROOT/tests/ref/corpus-adapt.py" "$ROOT/tests/corpus/puc54"
  echo "corpus re-extracted from lua/lua $LUA_GH_COMMIT (local adaptations reapplied)"
fi
echo "reference ready: $HERE/bin/lua54ref"
