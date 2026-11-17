#!/bin/sh
# Fetch and pin the classic benchmark sources into .dlcache/bench (networked host only).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DEST="$ROOT/.dlcache/bench"
HERE="$ROOT/tests/bench/classic"
mkdir -p "$DEST"
cd "$DEST"

while IFS='	' read -r file url sha src commit; do
  case "$file" in ''|'#'*) continue ;; esac
  if [ ! -f "$file" ] || [ "$(sha256sum "$file" | cut -d' ' -f1)" != "$sha" ]; then
    if [ "$file" = "input.fasta" ]; then
      echo "input.fasta must be generated (see manifest)" >&2
      exit 1
    fi
    echo "fetch: $file"
    curl -fL --retry 3 -o "$file" "$url"
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { echo "checksum mismatch for $file" >&2; exit 1; }
  else
    echo "cached: $file"
  fi
done < "$HERE/manifest.txt"

rm -rf src
mkdir -p src src/deltablue
tar xzf lua-benchmarks-gl-e1b3f24.tar.gz -C src --strip-components=1
tar xzf deltablue-73f4a24.tar.gz -C src/deltablue --strip-components=1
echo "classic sources ready in $DEST/src"
