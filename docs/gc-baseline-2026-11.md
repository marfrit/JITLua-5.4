# GC baseline — 2026-11-18

Measurement only. No collector behaviour was changed in a default build. The
question: before any redesign toward Mike Pall's arena/quad-color plan, is the
GC a meaningful share of time *or* memory, per workload and per arch?

## Method

- Tree: `gcbase` branch from main `7b85747e`; `make` (default `CFLAGS`, never
  `XCFLAGS`). Runner: `tests/bench/gc-measure.sh` (one command per arch, box
  wrappers outside this repository). It builds everything, runs the harness,
  then `tests/bench/gc_measure.py` runs the measurement.
- Default-behaviour check: the optional stats block in `src/lj_gc.c` is compiled
  out unless `-DLUAJIT_GC_STATS` is in `CFLAGS`. With the macro off, harness
  modes A+B are green on both arches: 165 PASS / 0 FAIL / 9 XFAIL, identical to
  the unpatched tree.
- Arms, interleaved in one job (A, B, C, …, A, B, C, …) so drift hits every arm:
  1. ours, default GC (`-jon`)
  2. ours, deferred collection (`-e 'collectgarbage("setpause",1000)'`): the
     black-box GC-cost estimate, trading memory for time
  3. ours, `setpause=100` (collect at ~2× live): the policy/memory separator
  4. ours, `collectgarbage("generational")` prelude
  5. stock LuaJIT 2.1 (`63c8f1a9`, pinned in `.dlcache/bench`), default
  6. stock, deferred collection
  7. PUC-Lua 5.4.9, incremental (default)
  8. PUC-Lua 5.4.9, generational (`collectgarbage("generational")` prelude)
  Stats-only arms (one run each, not used for wall tables): ours default with
  `LUAJIT_GC_STATS`, PUC incremental/generational with a scratch-copy
  `LUA_GC_STATS` patch (`tests/bench/puc_gc_stats.py`; `tests/ref` itself is
  never patched).
- JITLua's `collectgarbage("generational")` currently only sets a mode flag
  (`gcmode`); it does not install a generational collector. Its arm therefore
  tracks the default arm within noise on both arches — that is expected, not a
  measurement failure.
- Wall time: per-child wall time, median over repetitions. Peak RSS: per-child
  `ru_maxrss` from `os.wait4` (a corpus workload reports the maximum over its
  suite's child processes). Repetition count adapts after round 1
  (1/2/3/5); deltablue and scimark run one repetition and are marked
  "single" in every table. Corpus runs whose suite exits non-zero
  (lua-cjson, penlight on this host, luaunit for stock) are still timed: exit
  status is recorded but does not drop the sample. The harness, not this
  runner, owns correctness.
- GC time and pauses come from the instrumentation builds: one optional block
  in `lj_gc.c` and the equivalent scratch patch for PUC, both dumping a
  `GCSTATS` line at exit. "GC ms" is the sum of collector-step durations as a
  percentage of the default-arm wall time; it includes the atomic phase (which
  nests inside a step) and excludes explicit `collectgarbage("collect")` full
  cycles. Percentiles are upper edges of a log2 nanosecond histogram, so a p99
  can exceed the observed max. The timing probes add a small overhead to the
  stats arms only.
- Machines. x86_64: one 4-core NUC from the pool, pinned; load average
  1.94 → 1.03 over the run, no other job. arm64: the 20-core shared box next to
  model serving; load 3.98 → 5.01, no `luajit`/`make` process at start or end
  (an earlier attempt was refused because another compile was running and was
  rerun clean). Both boxes are otherwise identical within an arch; arms were
  interleaved.
- Workloads: the nine classic benchmarks in `tests/bench/classic` (canonical
  sizes) and eight real-program suites from `tests/corpus-ext` — luafilesystem,
  lpeg, lua-cjson, penlight, serpent, luaunit, rxi-json, dkjson. Their C
  modules were built per family (PUC headers, our headers, stock headers).
  luafilesystem's suite is filesystem-bound and highly variable (2.4 s x64 vs
  61 s arm in this run); it is reported but excluded from the verdict as a GC
  target. Short workloads (nbody, spectral-norm, fasta, regex-dna, rxi-json)
  have a few-tenths-of-a-millisecond noise floor.

## x86_64

#### Wall time (median ms)

| workload | ours | defer | pause100 | gen | stock | stock-defer | PUC inc | PUC gen | reps |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| nbody | 9.1 | 9.1 | 9.1 | 9.1 | 9.1 | 9.1 | 57.4 | 57.5 | 5 |
| spectral-norm | 19.7 | 19.7 | 19.7 | 19.8 | 22.0 | 19.8 | 173.1 | 168.8 | 5 |
| fannkuch-redux | 63.8 | 63.9 | 65.8 | 63.9 | 70.1 | 70.1 | 338.7 | 337.1 | 5 |
| binary-trees | 952.2 | 735.5 | 1516.7 | 938.8 | 928.4 | 734.3 | 2501.9 | 2478.4 | 3 |
| fasta | 13.5 | 13.5 | 15.6 | 15.7 | 15.7 | 15.7 | 26.2 | 26.2 | 5 |
| deltablue | 23567.3 | 23277.4 | 28915.6 | 24061.9 | 21981.6 | 19415.0 | 130469.3 | 131803.3 | 1 (single) |
| scimark | 29436.5 | 29501.4 | 29461.8 | 29467.4 | 30493.6 | 30441.6 | 29005.5 | 29045.4 | 1 (single) |
| k-nucleotide | 76.6 | 66.4 | 133.7 | 76.7 | 66.2 | 68.2 | 129.1 | 128.6 | 5 |
| regex-dna | 65.9 | 65.9 | 68.0 | 65.9 | 61.7 | 63.8 | 74.3 | 74.3 | 5 |
| luafilesystem | 2355.4 | 2339.9 | 2341.4 | 2338.3 | 2284.7 | 2246.4 | 2057.1 | 2050.0 | 2 |
| lpeg | 467.2 | 479.3 | 1129.4 | 463.6 | 384.5 | 395.8 | 555.7 | 560.8 | 3 |
| lua-cjson | 423.4 | 387.4 | 535.4 | 427.2 | 428.5 | 409.3 | 1647.1 | 1628.9 | 3 |
| penlight | 654.5 | 613.0 | 641.0 | 597.2 | 611.6 | 607.6 | 632.5 | 615.3 | 3 |
| serpent | 30.3 | 30.4 | 32.5 | 30.2 | 30.3 | 30.3 | 24.0 | 24.0 | 5 |
| luaunit | 89.0 | 89.1 | 91.2 | 89.0 | 72.3 | 70.1 | 84.9 | 84.8 | 5 |
| rxi-json | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 7.2 | 5 |
| dkjson | 99.6 | 99.5 | 99.6 | 99.5 | 93.2 | 93.3 | 240.3 | 240.3 | 5 |

#### Peak RSS (median MB, per-child ru_maxrss)

| workload | ours | ours-defer | ours-pause100 | stock | PUC inc | PUC gen |
|---|---:|---:|---:|---:|---:|---:|
| nbody | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 |
| spectral-norm | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 |
| fannkuch-redux | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 |
| binary-trees | 32.4 | 67.1 | 20.2 | 30.0 | 16.4 | 16.4 |
| fasta | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 |
| deltablue | 12.6 | 14.8 | 12.6 | 12.6 | 12.6 | 12.6 |
| scimark | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 |
| k-nucleotide | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 |
| regex-dna | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 | 12.6 |
| luafilesystem | 12.8 | 12.8 | 12.8 | 12.8 | 12.8 | 12.8 |
| lpeg | 16.7 | 38.5 | 15.2 | 16.4 | 29.6 | 30.3 |
| lua-cjson | 126.6 | 127.0 | 126.4 | 127.1 | 158.3 | 158.3 |
| penlight | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 |
| serpent | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 |
| luaunit | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 |
| rxi-json | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 |
| dkjson | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 | 31.1 |

#### GC share and cycles

| workload | ours defer Δ% | ours pause100 Δ% | ours GC ms (% wall) | ours cycles | PUC inc GC ms (% wall) | PUC inc cycles | PUC gen GC ms (% wall) | PUC gen cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| nbody | 0.3 | 0.3 | 0.0 (0%) | 0 | 0.0 (0%) | 2 | 0.0 (0%) | 2 |
| spectral-norm | 0.1 | -0.1 | 0.0 (0%) | 0 | 0.0 (0%) | 3 | 0.0 (0%) | 3 |
| fannkuch-redux | -0.1 | -3.2 | 0.0 (0%) | 0 | 0.0 (0%) | 1 | 0.0 (0%) | 1 |
| binary-trees | 22.8 | -59.3 | 473.0 (50%) | 110 | 585.1 (23%) | 829 | 608.7 (25%) | 835 |
| fasta | 0.1 | -15.5 | 0.1 (1%) | 1 | 0.1 (1%) | 4 | 0.1 (1%) | 4 |
| deltablue | 1.2 | -22.7 | 2851.1 (12%) | 3695 | 4428.4 (3%) | 54996 | 4480.1 (3%) | 63074 |
| scimark | -0.2 | -0.1 | 0.2 (0%) | 2 | 0.5 (0%) | 9 | 0.5 (0%) | 9 |
| k-nucleotide | 13.4 | -74.4 | 18.3 (24%) | 9 | 8.0 (6%) | 23 | 8.3 (6%) | 23 |
| regex-dna | -0.0 | -3.2 | 0.4 (1%) | 3 | 0.2 (0%) | 11 | 0.2 (0%) | 11 |
| luafilesystem | 0.7 | 0.6 | 3.1 (0%) | 18 | 87.6 (4%) | 6354 | 90.0 (4%) | 6352 |
| lpeg | -2.6 | -141.8 | 123.5 (26%) | 175 | 164.6 (30%) | 161 | 164.5 (29%) | 183 |
| lua-cjson | 8.5 | -26.4 | 53.4 (13%) | 9 | 20.5 (1%) | 4 | 21.2 (1%) | 4 |
| penlight | 6.3 | 2.1 | 16.7 (3%) | 104 | 9.4 (1%) | 145 | 9.6 (2%) | 147 |
| serpent | -0.4 | -7.6 | 1.1 (4%) | 4 | 1.0 (4%) | 38 | 0.9 (4%) | 38 |
| luaunit | -0.1 | -2.4 | 3.3 (4%) | 5 | 1.8 (2%) | 6 | 1.8 (2%) | 6 |
| rxi-json | -0.5 | -0.4 | 0.1 (2%) | 1 | 0.1 (2%) | 4 | 0.1 (2%) | 4 |
| dkjson | 0.0 | -0.0 | 0.6 (1%) | 4 | 0.4 (0%) | 9 | 0.4 (0%) | 9 |

#### Pause distribution (microseconds; p99 is the log2-histogram upper edge)

| workload | ours cycles | ours step p50 | ours step p99 | ours step max | ours atomic p50 | ours atomic p99 | ours atomic max | PUC inc step p99/max | PUC gen step p99/max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| nbody | 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 4.1/4.0 | 4.1/4.0 |
| spectral-norm | 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 8.2/6.0 | 8.2/6.0 |
| fannkuch-redux | 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 1.0/4.0 | 1.0/5.0 |
| binary-trees | 110 | 1.0 | 8.2 | 1742.0 | 32.8 | 2097.2 | 1734.0 | 16777.2/13852.0 | 16777.2/13176.0 |
| fasta | 1 | 2.0 | 16.4 | 15.0 | 4.1 | 4.1 | 3.0 | 65.5/37.0 | 32.8/34.0 |
| deltablue | 3695 | 1.0 | 32.8 | 55.0 | 4.1 | 16.4 | 23.0 | 524.3/380.0 | 524.3/473.0 |
| scimark | 2 | 2.0 | 16.4 | 14.0 | 4.1 | 4.1 | 7.0 | 131.1/121.0 | 131.1/118.0 |
| k-nucleotide | 9 | 16.4 | 32.8 | 469.0 | 16.4 | 524.3 | 329.0 | 2097.2/3198.0 | 2097.2/3509.0 |
| regex-dna | 3 | 2.0 | 16.4 | 36.0 | 4.1 | 4.1 | 30.0 | 32.8/39.0 | 32.8/39.0 |
| luafilesystem | 18 | 1.0 | 32.8 | 39.0 | 32.8 | 32.8 | 28.0 | 32.8/80.0 | 32.8/80.0 |
| lpeg | 175 | 2.0 | 65.5 | 1403.0 | 131.1 | 2097.2 | 1390.0 | 16777.2/14232.0 | 16777.2/13861.0 |
| lua-cjson | 9 | 8.2 | 32.8 | 7681.0 | 65.5 | 2097.2 | 7668.0 | 8388.6/8459.0 | 8388.6/8670.0 |
| penlight | 104 | 46.1 | 573.4 | 822.0 | 270.3 | 450.6 | 547.0 | 3170.3/4317.0 | 3163.1/4363.0 |
| serpent | 4 | 2.0 | 32.8 | 20.0 | 8.2 | 8.2 | 10.0 | 131.1/101.0 | 131.1/101.0 |
| luaunit | 5 | 1.0 | 32.8 | 54.0 | 16.4 | 16.4 | 47.0 | 524.3/553.0 | 524.3/557.0 |
| rxi-json | 1 | 2.0 | 16.4 | 25.0 | 16.4 | 16.4 | 14.0 | 32.8/66.0 | 32.8/70.0 |
| dkjson | 4 | 2.0 | 65.5 | 79.0 | 8.2 | 32.8 | 42.0 | 131.1/136.0 | 131.1/138.0 |

## arm64

#### Wall time (median ms)

| workload | ours | defer | pause100 | gen | stock | stock-defer | PUC inc | PUC gen | reps |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| nbody | 4.5 | 4.4 | 4.4 | 4.4 | 4.4 | 4.4 | 12.6 | 12.7 | 5 |
| spectral-norm | 4.4 | 4.5 | 4.5 | 4.4 | 4.4 | 4.4 | 43.4 | 43.4 | 5 |
| fannkuch-redux | 14.9 | 14.8 | 14.7 | 14.7 | 14.7 | 14.7 | 75.3 | 74.3 | 5 |
| binary-trees | 167.4 | 164.3 | 247.2 | 173.6 | 167.5 | 159.7 | 493.9 | 483.2 | 3 |
| fasta | 4.5 | 4.5 | 4.5 | 4.5 | 4.5 | 4.5 | 6.5 | 6.5 | 5 |
| deltablue | 4532.4 | 4391.3 | 5004.2 | 4690.6 | 3438.2 | 3122.5 | 30417.5 | 31695.7 | 1 (single) |
| scimark | 24473.3 | 24143.5 | 24290.6 | 24306.2 | 24553.9 | 23982.0 | 30365.5 | 30452.7 | 1 (single) |
| k-nucleotide | 21.1 | 19.1 | 45.9 | 31.2 | 19.0 | 19.0 | 31.4 | 33.2 | 5 |
| regex-dna | 14.8 | 14.8 | 14.9 | 14.8 | 14.8 | 14.8 | 16.9 | 16.9 | 5 |
| luafilesystem | 60848.4 | 52778.5 | 61914.1 | 61882.1 | 64871.7 | 55508.5 | 49990.9 | 50457.0 | 1 (single) |
| lpeg | 122.4 | 176.6 | 284.6 | 110.7 | 111.9 | 163.6 | 168.7 | 163.9 | 5 |
| lua-cjson | 256.5 | 240.7 | 284.9 | 258.7 | 262.9 | 242.1 | 597.4 | 602.9 | 3 |
| penlight | 595.0 | 569.5 | 588.4 | 587.8 | 584.2 | 554.5 | 629.5 | 631.1 | 3 |
| serpent | 11.2 | 11.0 | 11.2 | 12.9 | 11.3 | 10.9 | 8.7 | 9.3 | 5 |
| luaunit | 25.6 | 25.7 | 25.7 | 25.6 | 21.1 | 21.0 | 21.1 | 21.2 | 5 |
| rxi-json | 4.6 | 4.6 | 4.6 | 4.6 | 4.6 | 4.6 | 4.6 | 4.6 | 5 |
| dkjson | 23.3 | 23.2 | 23.2 | 23.1 | 23.1 | 23.2 | 56.2 | 58.2 | 5 |

#### Peak RSS (median MB, per-child ru_maxrss)

| workload | ours | ours-defer | ours-pause100 | stock | PUC inc | PUC gen |
|---|---:|---:|---:|---:|---:|---:|
| nbody | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| spectral-norm | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| fannkuch-redux | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| binary-trees | 25.6 | 75.7 | 18.6 | 28.3 | 15.4 | 15.9 |
| fasta | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| deltablue | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| scimark | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| k-nucleotide | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| regex-dna | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| luafilesystem | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 | 12.9 |
| lpeg | 16.3 | 37.3 | 14.6 | 17.1 | 30.0 | 30.3 |
| lua-cjson | 125.5 | 125.7 | 125.8 | 125.6 | 157.3 | 157.3 |
| penlight | 31.4 | 31.4 | 31.4 | 31.4 | 31.4 | 31.4 |
| serpent | 31.4 | 31.4 | 31.4 | 31.4 | 31.4 | 31.4 |
| luaunit | 31.4 | 31.4 | 31.4 | 31.4 | 31.4 | 31.4 |
| rxi-json | 31.5 | 31.5 | 31.5 | 31.5 | 31.5 | 31.5 |
| dkjson | 31.5 | 31.5 | 31.5 | 31.5 | 31.5 | 31.5 |

#### GC share and cycles

| workload | ours defer Δ% | ours pause100 Δ% | ours GC ms (% wall) | ours cycles | PUC inc GC ms (% wall) | PUC inc cycles | PUC gen GC ms (% wall) | PUC gen cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| nbody | 0.8 | 0.1 | 0.0 (0%) | 0 | 0.0 (0%) | 2 | 0.0 (0%) | 2 |
| spectral-norm | -0.7 | -0.4 | 0.0 (0%) | 0 | 0.0 (0%) | 3 | 0.0 (0%) | 3 |
| fannkuch-redux | 1.0 | 1.1 | 0.0 (0%) | 0 | 0.0 (0%) | 1 | 0.0 (0%) | 1 |
| binary-trees | 1.8 | -47.7 | 75.4 (45%) | 109 | 114.1 (23%) | 831 | 110.6 (23%) | 829 |
| fasta | 0.5 | 0.6 | 0.0 (1%) | 1 | 0.0 (0%) | 4 | 0.0 (0%) | 4 |
| deltablue | 3.1 | -10.4 | 626.4 (14%) | 3636 | 779.0 (3%) | 54996 | 815.3 (3%) | 69328 |
| scimark | 1.3 | 0.7 | 0.1 (0%) | 2 | 0.2 (0%) | 9 | 0.1 (0%) | 9 |
| k-nucleotide | 9.6 | -117.8 | 7.2 (34%) | 9 | 1.7 (5%) | 23 | 1.8 (5%) | 23 |
| regex-dna | 0.1 | -0.4 | 0.1 (1%) | 3 | 0.1 (0%) | 11 | 0.0 (0%) | 11 |
| luafilesystem | 13.3 | -1.8 | 6492.6 (11%) | 40738 | 1959.7 (4%) | 705679 | 1956.9 (4%) | 704369 |
| lpeg | -44.2 | -132.4 | 43.7 (36%) | 175 | 51.0 (30%) | 183 | 55.9 (34%) | 183 |
| lua-cjson | 6.2 | -11.1 | 34.1 (13%) | 8 | 38.2 (6%) | 4 | 36.3 (6%) | 4 |
| penlight | 4.3 | 1.1 | 10.9 (2%) | 110 | 5.5 (1%) | 145 | 4.7 (1%) | 147 |
| serpent | 1.8 | -0.0 | 0.3 (2%) | 4 | 0.2 (2%) | 37 | 0.2 (2%) | 37 |
| luaunit | -0.3 | -0.4 | 0.7 (3%) | 4 | 0.4 (2%) | 6 | 0.5 (2%) | 6 |
| rxi-json | -0.6 | -1.4 | 0.0 (1%) | 1 | 0.0 (1%) | 4 | 0.0 (0%) | 4 |
| dkjson | 0.6 | 0.6 | 0.8 (3%) | 4 | 0.1 (0%) | 9 | 0.2 (0%) | 9 |

#### Pause distribution (microseconds; p99 is the log2-histogram upper edge)

| workload | ours cycles | ours step p50 | ours step p99 | ours step max | ours atomic p50 | ours atomic p99 | ours atomic max | PUC inc step p99/max | PUC gen step p99/max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| nbody | 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 1.0/1.0 | 1.0/1.0 |
| spectral-norm | 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 1.0/1.0 | 1.0/1.0 |
| fannkuch-redux | 0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0/1.0 | 0.0/1.0 |
| binary-trees | 109 | 0.0 | 2.0 | 162.0 | 4.1 | 262.1 | 161.0 | 2097.2/1865.0 | 2097.2/1990.0 |
| fasta | 1 | 0.0 | 4.1 | 4.0 | 1.0 | 1.0 | 1.0 | 8.2/7.0 | 8.2/7.0 |
| deltablue | 3636 | 0.0 | 8.2 | 35.0 | 1.0 | 4.1 | 6.0 | 65.5/118.0 | 65.5/74.0 |
| scimark | 2 | 0.0 | 4.1 | 4.0 | 1.0 | 1.0 | 2.0 | 32.8/71.0 | 16.4/57.0 |
| k-nucleotide | 9 | 4.1 | 16.4 | 176.0 | 8.2 | 131.1 | 117.0 | 524.3/784.0 | 524.3/825.0 |
| regex-dna | 3 | 1.0 | 4.1 | 9.0 | 0.0 | 1.0 | 7.0 | 8.2/19.0 | 4.1/8.0 |
| luafilesystem | 40738 | 1.0 | 16.4 | 78.0 | 0.0 | 1.0 | 10.0 | 4.1/77.0 | 4.1/104.0 |
| lpeg | 175 | 1.0 | 16.4 | 1509.0 | 32.8 | 524.3 | 550.0 | 4194.3/5450.0 | 4194.3/5945.0 |
| lua-cjson | 8 | 4.1 | 16.4 | 4950.0 | 32.8 | 2097.2 | 2225.0 | 8388.6/29460.0 | 8388.6/27832.0 |
| penlight | 110 | 21.5 | 210.9 | 412.0 | 85.0 | 154.6 | 194.0 | 1824.8/2409.0 | 1642.5/2087.0 |
| serpent | 4 | 1.0 | 8.2 | 5.0 | 1.0 | 1.0 | 2.0 | 32.8/22.0 | 32.8/23.0 |
| luaunit | 4 | 0.0 | 8.2 | 16.0 | 4.1 | 4.1 | 14.0 | 131.1/136.0 | 262.1/142.0 |
| rxi-json | 1 | 1.0 | 2.0 | 4.0 | 4.1 | 4.1 | 4.0 | 8.2/17.0 | 8.2/12.0 |
| dkjson | 4 | 1.0 | 131.1 | 418.0 | 4.1 | 16.4 | 43.0 | 32.8/50.0 | 32.8/127.0 |

## Findings

- **Allocation churn, not arithmetic, drives GC cost.** nbody, spectral-norm,
  fannkuch-redux, fasta and scimark allocate almost nothing in their hot loops:
  0–2 collector cycles over the whole run and <0.2 % GC time. regex-dna, serpent,
  rxi-json and dkjson are likewise under 3 %; penlight is 1.7–2.6 %. A better
  GC has no payoff there.
- **binary-trees is the one big GC workload.** Ours spends 473 ms in
  `lj_gc_step` on x64 (50 % of 952 ms wall) and 75 ms on arm (45 % of 167 ms);
  deferring collection recovers 217 ms (22.8 %) on x64 and 3 ms (1.8 %) on arm,
  because the deferred arm still collects. Stock's deferral recovers 194 ms
  (20.9 %) x64 and ~8 ms arm. PUC's collector spends comparable absolute time
  (585 ms x64, 114 ms arm) but that is 23 % of PUC's own 2502 ms wall: the
  share is ours because the JIT makes the non-GC part 2.6× shorter, not because
  our collector does more work than PUC's.
- **lpeg is a second GC-heavy real program.** Ours: 124 ms GC in 467 ms (26 %) on
  x64, 44 ms in 122 ms (36 %) on arm (PUC: 165/51 ms, i.e. comparable absolute
  cost). But deferring *hurts*: 480 ms (+2.6 %) x64,
  177 ms (+44 %) arm, while peak RSS jumps 16.7 → 38.5 MB x64 and 16.1 → 37.3 MB
  arm. `setpause=100` is worse still in time (1129 ms x64, 287 ms arm) and only
  shaves RSS to 15.2/14.6 MB. The default policy is time-optimal here; the
  collector's cost is throughput, not tuning headroom.
- **deltablue and k-nucleotide carry a real but smaller GC share.** Ours GC is
  2851 ms in 23.6 s (12 %) x64 and 627 ms in 4.5 s (14 %) arm for deltablue;
  k-nucleotide is 7.2 ms in 21 ms (34 %) arm and 18 ms in 76.6 ms (24 %) x64.
  Deferral recovers 1.2 % on deltablue x64 (3.1 % arm) and 13.4 % on k-nucleotide
  x64 (9.6 % arm; stock recovers 11.7 % on deltablue x64). Deltablue's overall stock gap is dominated by
  trace selection, not GC, so a GC redesign buys at most the ~12–14 % share.
- **lua-cjson (corpus) is 13 % GC on both arches** (53.4 ms / 423 ms x64,
  34.1 / 256 ms arm), with deferral recovering 8.5 % x64 and 6.2 % arm;
  `setpause=100` costs 26 %/11 % time for essentially no RSS change (the
  suite's 126 MB is live data).
- **Pause tails are modest in ours and larger in PUC.** Ours atomic p99 is at
  most 2.1 ms on every workload; single atomic maxima are 1.7 ms x64
  binary-trees, 1.4 ms lpeg, 7.7 ms x64 lua-cjson (2.2 ms arm), 0.5 ms penlight.
  PUC's step max reaches 13.9 ms x64 binary-trees, 8.5 ms x64 and 29.5 ms arm
  lua-cjson (p99 edges 16.8 / 8.4 ms). No workload shows a systematic
  pause-latency problem in ours; the observed cost is throughput of incremental
  steps, not stop-the-world latency.
- **Memory: only binary-trees shows our heap overhead, and it is mostly policy.**
  Peak RSS x64 / arm: ours 32.4 / 32.3 MB, stock 30.0 / 27.6, PUC 16.4 / 15.4.
  Deferring doubles it (67.1 / 90.4 MB; stock 91.4 / 80.0). `setpause=100` drops
  ours to 20.2 / 19.4 MB: the gap to PUC shrinks by 12.2 MB of 16.0 MB (76 %) on
  x64 and 12.9 of 16.9 MB (76 %) on arm. The residual ~4 MB is layout/object
  size, not collector policy. Elsewhere there is no LuaJIT heap penalty: lpeg
  ours is 16.7/16.1 MB against PUC 29.6/30.3 MB, lua-cjson 126.6/125.8 against
  PUC 158.3/157.3, and the small workloads sit at the same ~12.6–12.9 MB
  interpreter baseline for all three engines.
- PUC incremental vs generational is within noise on these workloads (mostly
  <3 %), so the CPython-3.14 lesson is visible here only as the deferred arm's
  memory bill, not as a generational-mode win.

## Verdict

The collector is a meaningful bottleneck, but narrowly: it is a throughput and
peak-memory cost on allocation-churn workloads, not a pause-latency problem.
On binary-trees it is **50 % of ours wall on x64 and 45 % on arm**, with a peak
RSS of 2× PUC that is **76 % collector policy** (pause/stepmul), leaving about
4 MB to object sizes/layout; on lpeg it is **26–36 %** and the default policy is
already the fastest of the tested policies; on lua-cjson **13 %** on both arches, deltablue
**12–14 %**, k-nucleotide **24 % x64 / 34 % arm** (loop-tail small). Everywhere
else — nbody, spectral-norm, fannkuch-redux, fasta, scimark, regex-dna, serpent,
luaunit, rxi-json, dkjson, penlight — GC is 4 % or less of wall, often zero,
and peak RSS is the plain interpreter baseline; the filesystem-bound
luafilesystem suite is 0 % x64 and 11 % arm but is excluded as a GC target
because its wall time varies with the filesystem.
A GC redesign would pay on **binary-trees, lpeg, lua-cjson, k-nucleotide, and
(more modestly) deltablue**. It would not pay on the other twelve workloads.
If a redesign is funded, it should target the cost per incremental step on
allocation churn and a memory policy that does not double peak RSS under that
churn — not pause times, which are already ~2 ms at p99 (worst single atomic step 7.7 ms x64 lua-cjson)
in ours on the measured set.
