# Performance report — JITLua-5.4 1.0.0

Measurement of the classic benchmark set on both supported architectures,
JITLua-5.4 against PUC Lua 5.4.9 and stock LuaJIT 2.1. Run on 2026-11-21 on
the integration state before the review fixes of the release. This report
reads the figures; it does not change any source.

## Method

- Harness: `tests/bench/classic/` (sources pinned in `manifest.txt`). Three
  arms per benchmark: stock LuaJIT 2.1 with `-jon`, this fork with `-jon`, and
  PUC Lua 5.4.9.
- The classic stage reports the **median of 3** wall times per arm. One job
  ran at a time on each test host, and the three arms ran in the same job.
- Both architectures: Linux arm64 and Linux x86_64 (GC64). Each architecture
  was measured on one host. These are shared test hosts; other jobs ran on
  the x86_64 host during the run.
- Workloads: nbody 10000, spectral-norm 200, fannkuch-redux 9, binary-trees
  14, fasta 10000, deltablue (locals, 10000 iterations), scimark `-small`,
  k-nucleotide and regex-dna on a pinned 100 KB `input.fasta`.
- Times are in milliseconds. `stock/ours` above 1 means this fork is faster
  than stock LuaJIT; below 1, slower. `PUC/ours` above 1 means faster than
  PUC. Ratios are computed from the times in the table. The stage flags a
  benchmark when it is more than 10 % slower than stock.
- Output equality: stdout was identical across arms for every deterministic
  benchmark in the 2026-11-17 run; scimark prints process-defined rates and is
  not compared.

## Results, 2026-11-21

### arm64

| benchmark | stock ms | ours ms | PUC ms | stock/ours | PUC/ours |
|---|---:|---:|---:|---:|---:|
| nbody | 1.5 | 1.5 | 10.1 | 1.00 | 6.7 |
| spectral-norm | 2.0 | 2.0 | 40.0 | 1.00 | 20.0 |
| fannkuch-redux | 12.6 | 12.7 | 71.1 | 0.99 | 5.6 |
| binary-trees | 170.8 | 174.2 | 516.5 | 0.98 | 3.0 |
| fasta | 4.3 | 3.5 | 5.0 | 1.23 | 1.4 |
| deltablue | 3591.3 | 3186.5 | 31265.1 | 1.13 | 9.8 |
| scimark | 27304.0 | 25145.1 | 30773.4 | 1.09 | 1.2 |
| k-nucleotide | 23.1 | 24.3 | 36.0 | 0.95 | 1.5 |
| regex-dna | 13.6 | 14.3 | 28.6 | 0.95 | 2.0 |

In this run no arm64 benchmark is more than 10 % slower than stock.

### x86_64

| benchmark | stock ms | ours ms | PUC ms | stock/ours | PUC/ours |
|---|---:|---:|---:|---:|---:|
| nbody | 7.0 | 7.1 | 56.6 | 0.99 | 8.0 |
| spectral-norm | 15.5 | 16.2 | 170.1 | 0.96 | 10.5 |
| fannkuch-redux | 67.6 | 62.3 | 334.8 | 1.09 | 5.4 |
| binary-trees | 929.7 | 890.1 | 2449.0 | 1.04 | 2.8 |
| fasta | 9.8 | 11.7 | 17.3 | **0.84** | 1.5 |
| deltablue | 20125.5 | 19490.8 | 134374.2 | 1.03 | 6.9 |
| scimark | 30444.2 | 29588.0 | 28808.5 | 1.03 | 1.0 |
| k-nucleotide | 63.2 | 68.3 | 123.8 | 0.93 | 1.8 |
| regex-dna | 59.7 | 62.7 | 70.5 | 0.95 | 1.1 |

The stage flags one benchmark: **fasta, 0.84** on x86_64.

**Caveat on fasta.** fasta runs for about 10 ms. This value is the median of
three runs, measured while other jobs ran on the host, and a difference of
1.9 ms between the arms is within what that setup can produce. The
interleaved run of 2026-11-20 (median of 9, arms interleaved, one host per
architecture) measured fasta at 1.039 on x86_64 and 1.013 on arm64
(`docs/CHANGELOG-VM.md`, "Known JIT/performance rows"). The 0.84 is not
confirmed and has to be re-measured with the interleaved runner; it is listed
as open work in `docs/plan.md`.

Against PUC Lua 5.4.9 the fork is faster on every workload on both
architectures except scimark on x86_64, where the two are equal within the
precision of the table (1.0).

## Changes since 2026-11-17

The snapshot of 2026-11-17 is in
[bench-classic-2026-11-17.md](bench-classic-2026-11-17.md) (same method,
median of 3). It found four workloads more than 10 % slower than stock;
the 2026-11-21 run finds none of those.

| benchmark | arch | stock/ours 2026-11-17 | stock/ours 2026-11-21 |
|---|---|---:|---:|
| deltablue | arm64 | 0.62 (0.76 after the first bit fix) | 1.13 |
| deltablue | x86_64 | 0.69 | 1.03 |
| spectral-norm | x86_64 | 0.71 | 0.96 |
| k-nucleotide | arm64 | 0.88 | 0.95 |
| k-nucleotide | x86_64 | 0.87 | 0.93 |
| scimark | arm64 | 0.90 | 1.09 |

- **deltablue.** The missing-metamethod trace aborts came from a
  miscompilation in the alias analysis and the remainder from the weak-table
  guard; both are fixed. History: `docs/notes/deltablue.md`. The gap to stock
  is closed on both architectures.
- **spectral-norm.** The 0.71 of 2026-11-17 on x86_64 is not reproduced; the
  gap is closed to 0.96. The value 0.499 once reported for it was an artifact
  of the benchmark runner's timeout polling, not of the VM
  (`docs/CHANGELOG-VM.md`; `docs/notes/spectral.md`). The runner no longer
  polls.
- **k-nucleotide.** Parity came from the default collector pause (200 to 300);
  the cost is peak memory (`docs/notes/knuc-phase-align-2026-11.md`, and the
  GC policy section of the README). The run above reads 0.93 and 0.95, below
  the 10 % threshold.
- **Absolute times.** The arm64 stock times of the two dated runs differ for
  some workloads (fannkuch-redux 23.0 ms on 2026-11-17, 12.6 ms on
  2026-11-21). The cause was not investigated; compare the ratios, not the
  milliseconds, across the two dates.

For the same tree, the interleaved run of 2026-11-20 (median of 9) is the more
precise reference: every workload reads within 10 % of stock on both
architectures except arm64 nbody (0.731), a run of 1.3 ms. Measured alone on
that host, nbody reads 0.982 at the set's size and 0.993 and 0.997 at 10 and
100 times the iterations (`docs/CHANGELOG-VM.md`, "Known JIT/performance
rows").

## Limits of these figures

- Median of 3 and one host per architecture. Differences of a few percent
  are not significant, and for workloads that run for about 10 ms the noise is
  larger.
- Dead-slot clearing and the GC accounting of eliminated allocations are
  documented differences (`docs/DIFFERENCES.md`); a loop that allocates only
  to wait for the collector is not a benchmark of the VM.
- Only the classic set above was run for this report. Integer-specific
  workloads are covered by the notes under `docs/notes/` (for example
  `for-loop-54.md`), not by this table.
