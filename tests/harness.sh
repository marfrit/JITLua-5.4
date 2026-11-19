#!/bin/sh
# JITLua-5.4 differential verification harness (MISSION Phase 0).
#
#   tests/harness.sh                      # modes A + B over the whole corpus
#   tests/harness.sh --mode A             # interpreter vs PUC-Lua 5.4.9
#   tests/harness.sh --mode B --opt-levels 0,1,2,3
#   tests/harness.sh --mode R             # string.dump -> load -> re-run
#   tests/harness.sh --filter 'd54/numeric*' --verbose
#   tests/harness.sh --include-heavy   # opt-in OOM-heavy stage; needs >8G
#   tests/harness.sh --update-known-bad   # refresh the expected-failure baseline
#
# Environment overrides: LUAJIT (our binary), REF (PUC 5.4.9 binary).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LUAJIT=${LUAJIT:-$ROOT/src/luajit}
REF=${REF:-$ROOT/tests/ref/bin/lua54ref}

if ! command -v python3 >/dev/null 2>&1; then
  echo "harness: python3 is required" >&2
  exit 2
fi
if [ ! -x "$LUAJIT" ]; then
  echo "harness: $LUAJIT missing -- run 'make -j8' in $ROOT" >&2
  exit 2
fi
# The puc54 corpus loads C fixtures; build each arm's copy from its own headers
# (a PUC-built module is rejected by JITLua's luaL_checkversion).
CORPUS_LIBS_OUT=${CORPUS_LIBS_OUT:-$ROOT/tests/capi/build/corpus-libs}
export CORPUS_LIBS_OUT
sh "$ROOT/tests/ref/build-puc54-libs.sh" >&2
exec python3 "$ROOT/tests/lib/runner.py" --luajit "$LUAJIT" --ref "$REF" "$@"
