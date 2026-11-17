#!/bin/sh
# Run the classic benchmark stage inside one box job (offline).
# Sources are prefetched into .dlcache/bench; see manifest.txt/fetch.sh.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cd "$ROOT"
export XDG_CACHE_HOME="$ROOT/.dlcache"
exec python3 tests/bench/classic/run.py
