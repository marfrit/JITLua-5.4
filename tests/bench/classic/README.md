# Classic Lua benchmark stage

Measurement only. Compares **stock LuaJIT 2.1** (`-jon`), **this fork**
(`-jon`), and **PUC Lua 5.4.9** on the classic benchmark workloads. Median of
3 runs per arm, serially in one box job.

Sources are pinned by sha256 in `manifest.txt` and live in `.dlcache/bench/`;
`fetch.sh` downloads the two tarballs on a networked host, and `input.fasta`
is generated once from `fasta.lua` with the PUC reference. Boxes stay offline.
Not available in the pinned sources: richards, havlak (no Lua source found);
k-nucleotide/regex-dna use the pinned `input.fasta`.

Workloads: nbody 10000, spectral-norm 200, fannkuch-redux 9, binary-trees 14,
fasta 10000, deltablue locals (10000 iterations), scimark -small,
k-nucleotide and regex-dna on `input.fasta`.

Run on a box:

    arm-box -t 1800 sh tests/bench/classic/run.sh
    x64-box -t 1800 sh tests/bench/classic/run.sh

The script never fails on a slowdown: results are a report/table. stdout is
compared only where deterministic; scimark prints rates and is `result -`.
PUC-vs-ours stdout differences are flagged, not treated as errors; Lua 5.4
integer for-loops/division can legitimately change results. Do not "fix" a
benchmark to make it look fast.
