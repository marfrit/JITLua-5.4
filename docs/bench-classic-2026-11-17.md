# Classic benchmark comparison — 2026-11-17

Measurement only; no source changes and no benchmark "fixes". Median of 3 wall
times per arm, one box job at a time, same moment per arm. Arms: stock LuaJIT
2.1 `-jon`, this fork `-jon`, PUC Lua 5.4.9. Harness: `tests/bench/classic/`
(pinned sources in `manifest.txt`, fetched into `.dlcache/bench`; boxes offline).
Workloads: nbody 10000, spectral-norm 200, fannkuch-redux 9, binary-trees 14,
fasta 10000, deltablue locals (10000 iterations), scimark -small,
k-nucleotide + regex-dna on a pinned 100 KB `input.fasta`.

`stock/ours` > 1 means this fork faster; < 1 slower. Findings are ratios below
0.90 (more than 10% slower than stock). stdout was identical for every
deterministic benchmark; no 5.4 integer-semantics result differences were
observed in this workload set. SciMark prints process-defined rates, so its
stdout is not compared. richards and havlak were not available in the pinned
sources and are not included.

## arm64 (arm-box)

| benchmark | stock ms | ours ms | PUC ms | stock/ours | PUC/ours |
|---|---:|---:|---:|---:|---:|
| nbody | 1.8 | 1.5 | 10.4 | 1.20 | 7.0 |
| spectral-norm | 2.1 | 2.1 | 41.7 | 1.00 | 20.0 |
| fannkuch-redux | 23.0 | 23.2 | 86.7 | 0.99 | 3.7 |
| binary-trees | 171.0 | 183.1 | 502.3 | 0.93 | 2.7 |
| fasta | 3.3 | 3.0 | 4.8 | 1.10 | 1.6 |
| deltablue | 3545.3 | 5685.8 | 30383.3 | **0.62** | 5.3 |
| scimark | 23578.0 | 26321.6 | 29863.4 | **0.90** | 1.1 |
| k-nucleotide | 15.0 | 17.1 | 45.5 | **0.88** | 2.7 |
| regex-dna | 12.0 | 12.7 | 14.7 | 0.94 | 1.2 |

Arm64 findings (>10% slower): **deltablue 0.62 (~38%)**, **scimark 0.90
(~11%)**, **k-nucleotide 0.88 (~12%)**.

## x86_64 (x64-box)

| benchmark | stock ms | ours ms | PUC ms | stock/ours | PUC/ours |
|---|---:|---:|---:|---:|---:|
| nbody | 6.9 | 6.9 | 56.4 | 1.00 | 8.1 |
| spectral-norm | 15.5 | 21.9 | 174.2 | **0.71** | 8.0 |
| fannkuch-redux | 66.0 | 60.0 | 334.1 | 1.10 | 5.6 |
| binary-trees | 925.0 | 942.5 | 2493.0 | 0.98 | 2.6 |
| fasta | 9.8 | 9.3 | 17.1 | 1.10 | 1.8 |
| deltablue | 19042.8 | 27450.5 | 130805.5 | **0.69** | 4.8 |
| scimark | 30466.6 | 31133.4 | 28840.8 | 0.98 | 0.9 |
| k-nucleotide | 66.2 | 76.0 | 126.8 | **0.87** | 1.7 |
| regex-dna | 59.8 | 62.3 | 70.4 | 0.96 | 1.1 |

x86_64 findings (>10% slower): **spectral-norm 0.71 (~29%)**, **deltablue
0.69 (~31%)**, **k-nucleotide 0.87 (~13%)**.

## Handoff

Fable/VM owner: deltablue is the largest and arch-independent regression
(~31–38%). spectral-norm is x64-specific (~29%). k-nucleotide is ~12–13% on
both. Arm64 also has scimark ~11%. The other six workloads are within noise or
faster. Hypotheses are not established here; measurement only.
