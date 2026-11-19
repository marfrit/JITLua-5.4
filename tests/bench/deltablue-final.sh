#!/bin/sh
# deltablue-final.sh -- final evidence for the merged tree: stock vs fork
# deltablue trace census (-jv) and interleaved timing (-jon, -joff).
#
#   X64_BOX_HOST=pve1 x64-box -t 2400 sh tests/bench/deltablue-final.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
NPROC=$(nproc 2>/dev/null || echo 4)

make -j"$NPROC" >/tmp/df-fork.log 2>&1 || { tail -30 /tmp/df-fork.log; exit 1; }
STOCK=$ROOT/tmp/stock-final/src/luajit
if [ ! -x "$STOCK" ]; then
  rm -rf "$ROOT/tmp/stock-final"; mkdir -p "$ROOT/tmp/stock-final"
  tar xzf "$ROOT/.dlcache/bench/luajit-63c8f1a9.tar.gz" -C "$ROOT/tmp/stock-final"
  base=$(find "$ROOT/tmp/stock-final" -maxdepth 1 -mindepth 1 -type d | head -1)
  ( cd "$base" && make -j"$NPROC" ) >/tmp/df-stock.log 2>&1 || { tail -30 /tmp/df-stock.log; exit 1; }
  mv "$base"/* "$ROOT/tmp/stock-final"/ 2>/dev/null || true
  rmdir "$base" 2>/dev/null || true
fi
OURS=$ROOT/src/luajit
SRC=$ROOT/.dlcache/bench/src/deltablue
median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

for arm in stock ours; do
  case $arm in stock) BIN=$STOCK; JITDIR=$ROOT/tmp/stock-final/src ;; ours) BIN=$OURS; JITDIR=$ROOT/src ;; esac
  export LUA_PATH="$JITDIR/?.lua;;"
  ( cd "$SRC" && "$BIN" -jon -jv deltablue-10000iterations.lua locals ) > /tmp/df-$arm-jv.txt 2>&1 || true
done

echo "=== trace census (-jon -jv, one layout) ==="
for arm in stock ours; do
  echo "--- $arm ---"
  printf 'started %s  aborted %s  blacklist %s\n' \
    "$(grep -c '^\[TRACE' /tmp/df-$arm-jv.txt || true)" \
    "$(grep -c '^\[TRACE ---' /tmp/df-$arm-jv.txt || true)" \
    "$(grep -c blacklist /tmp/df-$arm-jv.txt || true)"
  grep '^\[TRACE ---' /tmp/df-$arm-jv.txt | sed 's/.* -- \(.*\) at \([^]]*\)\]/\1 | \2/' | sort | uniq -c | sort -rn | head -8
done

for opt in -jon -joff; do
  s=""; o=""; i=1
  while [ $i -le 7 ]; do
    for arm in stock ours; do
      case $arm in stock) BIN=$STOCK ;; ours) BIN=$OURS ;; esac
      t0=$(date +%s%N)
      ( cd "$SRC" && "$BIN" $opt deltablue-10000iterations.lua locals >/dev/null 2>&1 ) || true
      t1=$(date +%s%N)
      ms=$(( (t1 - t0) / 1000000 ))
      case $arm in stock) s="$s $ms" ;; ours) o="$o $ms" ;; esac
    done
    i=$((i+1))
  done
  sm=$(printf '%s\n' $s | median); om=$(printf '%s\n' $o | median)
  printf '%-6s stock_med=%-6s ours_med=%-6s stock/ours=%.3f  stock:[%s ] ours:[%s ]\n' \
    "$opt" "$sm" "$om" "$(awk -v a="$sm" -v b="$om" 'BEGIN{print a/b}')" "$s" "$o"
done
echo "=== done ==="
