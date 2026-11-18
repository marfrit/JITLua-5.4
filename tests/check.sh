#!/bin/sh
# Backend for `make check`: differential harness, modes A+B, over tests/d54.
#
# This is the same invocation as the A+B stage of tests/ci-box.sh:
#   tests/harness.sh --strict --mode both --corpus tests/d54 --timeout 120
#
# The PUC-Lua 5.4.9 reference is built only from a locally available tarball
# (the vendored tests/ref/dist copy, or an already populated download cache).
# If neither exists -- e.g. an offline package build that ships without the
# vendored tarball -- this prints one line and runs mode B alone (our JIT
# against our interpreter) instead of failing on a network download.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

REF_BIN=${REF:-$ROOT/tests/ref/bin/lua54ref}
TARBALL=lua-5.4.9.tar.gz
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/luajit54-dl

ref_runs() { [ -x "$REF_BIN" ] && "$REF_BIN" -v >/dev/null 2>&1; }

if ! ref_runs; then
  # Only the default location is rebuilt here; an explicit REF= points at a
  # binary this script must not overwrite.
  if [ "$REF_BIN" = "$ROOT/tests/ref/bin/lua54ref" ] &&
     { [ -f "tests/ref/dist/$TARBALL" ] || [ -f "$CACHE/$TARBALL" ] ||
       [ -f "$ROOT/.dlcache/luajit54-dl/$TARBALL" ]; }; then
    # A copied tree can carry a foreign-architecture reference binary; drop it
    # so fetch-ref.sh rebuilds, as ci-box.sh does.
    rm -f tests/ref/bin/lua54ref tests/ref/bin/luac54ref
    tests/ref/fetch-ref.sh || true
  fi
fi

MODE=both
if ! ref_runs; then
  echo "check: PUC 5.4.9 reference unavailable (no vendored tarball in tests/ref/dist or the download cache); running mode B only"
  MODE=B
fi

exec tests/harness.sh --strict --mode "$MODE" --corpus tests/d54 --timeout 120
