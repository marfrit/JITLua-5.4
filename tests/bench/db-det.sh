#!/bin/sh
# db-det.sh -- deterministic trace-census comparison. Builds stock and fork
# with a FIXED PRNG seed (LUAJIT_SECURITY_PRNG=0) so the penalty/blacklist
# randomness in lj_trace.c:penalty_pc() is reproducible, then runs the
# deltablue -jv census twice per arm and diffs the two arms.
#
#   X64_BOX_HOST=pve1 x64-box -t 2400 sh tests/bench/db-det.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
DET=-DLUAJIT_SECURITY_PRNG=0

echo "=== build stock (fixed seed) ==="
STOCK=$ROOT/tmp/stock-det/src/luajit
rm -rf "$ROOT/tmp/stock-det"; mkdir -p "$ROOT/tmp/stock-det"
tar xzf "$ROOT/.dlcache/bench/luajit-63c8f1a9.tar.gz" -C "$ROOT/tmp/stock-det"
base=$(find "$ROOT/tmp/stock-det" -maxdepth 1 -mindepth 1 -type d | head -1)
( cd "$base" && make -j"$NPROC" TARGET_CFLAGS="$DET" ) >/tmp/det-stock.log 2>&1 || { tail -30 /tmp/det-stock.log; exit 1; }
mv "$base"/* "$ROOT/tmp/stock-det"/ 2>/dev/null || true
rmdir "$base" 2>/dev/null || true
[ -x "$STOCK" ] || { echo "stock binary missing"; exit 1; }

echo "=== build fork (fixed seed) ==="
make clean >/dev/null 2>&1 || true
make -j"$NPROC" TARGET_CFLAGS="$DET" >/tmp/det-fork.log 2>&1 || { tail -30 /tmp/det-fork.log; exit 1; }
OURS=$ROOT/src/luajit

SRC=$ROOT/.dlcache/bench/src/deltablue
for arm in stock ours; do
  case $arm in
    stock) BIN=$STOCK; JITDIR=$ROOT/tmp/stock-det/src ;;
    ours)  BIN=$OURS;  JITDIR=$ROOT/src ;;
  esac
  export LUA_PATH="$JITDIR/?.lua;;"
  for rep in 1 2; do
    ( cd "$SRC" && "$BIN" -jon -jv deltablue-10000iterations.lua locals ) > /tmp/det-$arm-$rep.txt 2>&1 || true
  done
done

echo
echo "=== determinism check (same arm, two runs) ==="
for arm in stock ours; do
  if diff -q /tmp/det-$arm-1.txt /tmp/det-$arm-2.txt >/dev/null; then
    echo "$arm: identical"
  else
    echo "$arm: DIFFERS ($(diff /tmp/det-$arm-1.txt /tmp/det-$arm-2.txt | grep -c '^[<>]') lines)"
  fi
done

echo
echo "=== census ==="
for arm in stock ours; do
  echo "--- $arm ---"
  printf 'started %s  aborted %s  blacklist %s\n' \
    "$(grep -c '^\[TRACE' /tmp/det-$arm-1.txt || true)" \
    "$(grep -c '^\[TRACE ---' /tmp/det-$arm-1.txt || true)" \
    "$(grep -c blacklist /tmp/det-$arm-1.txt || true)"
  grep '^\[TRACE ---' /tmp/det-$arm-1.txt | sed 's/.* -- \(.*\) at \([^]]*\)\]/\1 | \2/' | sort | uniq -c | sort -rn | head -20
done

echo
echo "=== full -jv diff (stock vs ours) ==="
diff /tmp/det-stock-1.txt /tmp/det-ours-1.txt | head -150 || true

echo "=== done ==="
