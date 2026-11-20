#!/bin/sh
# perfdiag-run.sh -- one box job: build both arms, then run the diagnosis phases.
#
#   cd ~/src/LuaJIT-5.4-perfdiag
#   X64_BOX_HOST=<host> x64-box -t 3600 sh tests/bench/perfdiag-run.sh [phase ...]
# (x64-box is a private wrapper that runs a command on a remote x86_64 test
# host.)
#
# Measurement only: no source or benchmark changes. perfdiag.py builds stock
# LuaJIT 2.1 from the pinned tarball and extracts the pinned benchmark sources
# itself; this script only builds THIS fork and then walks the phases so that
# every arm runs on the same box in the same job.
set -e
cd "$(dirname "$0")/../.."
make -j4 >/tmp/pd-build.log 2>&1 || { tail -40 /tmp/pd-build.log; exit 1; }
PHASES=${*:-jv starts census ir mcode prof time knuc emptyinput gcfull teardown}
for ph in $PHASES; do
  python3 tests/bench/perfdiag.py "$ph" deltablue k-nucleotide
done
