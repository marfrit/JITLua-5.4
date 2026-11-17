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
      continue  # generated after the sources are unpacked
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

# Generate the shared k-nucleotide/regex-dna input once, with the PUC reference.
want=$(awk -F '	' '$1 == "input.fasta" {print $3}' "$HERE/manifest.txt")
if [ ! -f input.fasta ] || [ "$(sha256sum input.fasta | cut -d' ' -f1)" != "$want" ]; then
  [ -x "$ROOT/tests/ref/bin/lua54ref" ] || {
    echo "input.fasta needs the PUC reference: run tests/ref/fetch-ref.sh first" >&2
    exit 1
  }
  "$ROOT/tests/ref/bin/lua54ref" src/fasta.lua 10000 > input.fasta
  got=$(sha256sum input.fasta | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "checksum mismatch for generated input.fasta" >&2; exit 1; }
fi
echo "classic sources ready in $DEST/src"
