#!/bin/sh
# db-perturb.sh -- is the deltablue trace census sensitive to heap layout?
# Builds stock+fork with a fixed PRNG seed, then runs each arm with several
# LUA_INIT perturbations that shift the heap before the script's protos are
# allocated. If one binary's census moves a lot, trace selection is
# layout-dependent (hotcount is hashed on the pc address).
#
#   X64_BOX_HOST=pve1 x64-box -t 2400 sh tests/bench/db-perturb.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)
DET=-DLUAJIT_SECURITY_PRNG=0

STOCK=$ROOT/tmp/stock-det/src/luajit
if [ ! -x "$STOCK" ]; then
  rm -rf "$ROOT/tmp/stock-det"; mkdir -p "$ROOT/tmp/stock-det"
  tar xzf "$ROOT/.dlcache/bench/luajit-63c8f1a9.tar.gz" -C "$ROOT/tmp/stock-det"
  base=$(find "$ROOT/tmp/stock-det" -maxdepth 1 -mindepth 1 -type d | head -1)
  ( cd "$base" && make -j"$NPROC" TARGET_CFLAGS="$DET" ) >/tmp/p-stock.log 2>&1 || { tail -30 /tmp/p-stock.log; exit 1; }
  mv "$base"/* "$ROOT/tmp/stock-det"/ 2>/dev/null || true
  rmdir "$base" 2>/dev/null || true
fi
make -j"$NPROC" TARGET_CFLAGS="$DET" >/tmp/p-fork.log 2>&1 || { tail -30 /tmp/p-fork.log; exit 1; }
OURS=$ROOT/src/luajit
SRC=$ROOT/.dlcache/bench/src/deltablue

INIT1='local t={} for i=1,200 do t[i]={i,string.rep("z",i%40)} end t=nil'
INIT2='local t={} for i=1,2000 do t[i]={i,string.rep("y",i%97),tostring(i)} end t=nil'
INIT3='local t={} for i=1,50 do t[i]=string.rep("q",i*13) end t=nil'

for arm in stock ours; do
  case $arm in
    stock) BIN=$STOCK; JITDIR=$ROOT/tmp/stock-det/src ;;
    ours)  BIN=$OURS;  JITDIR=$ROOT/src ;;
  esac
  export LUA_PATH="$JITDIR/?.lua;;"
  echo "===== $arm ====="
  for tag in none i1 i2 i3; do
    case $tag in
      none) unset LUA_INIT ;;
      i1) LUA_INIT="$INIT1" ;;
      i2) LUA_INIT="$INIT2" ;;
      i3) LUA_INIT="$INIT3" ;;
    esac
    export LUA_INIT 2>/dev/null || true
    ( cd "$SRC" && "$BIN" -jon -jv deltablue-10000iterations.lua locals ) > /tmp/p-$arm-$tag.txt 2>&1 || true
    printf '%-5s started %-4s aborted %-4s blacklist %-3s\n' "$tag" \
      "$(grep -c '^\[TRACE' /tmp/p-$arm-$tag.txt || true)" \
      "$(grep -c '^\[TRACE ---' /tmp/p-$arm-$tag.txt || true)" \
      "$(grep -c blacklist /tmp/p-$arm-$tag.txt || true)"
  done
  unset LUA_INIT
done

echo "=== abort census per perturbation ==="
for arm in stock ours; do
  for tag in none i1 i2 i3; do
    echo "--- $arm/$tag ---"
    grep '^\[TRACE ---' /tmp/p-$arm-$tag.txt | sed 's/^\[TRACE --- //' | sort | uniq -c | sort -rn | head -5
  done
done
echo "=== done ==="
