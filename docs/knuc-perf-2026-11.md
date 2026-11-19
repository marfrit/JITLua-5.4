# k-nucleotide performance — measurement 2026-11-19 (branch knuc)

Measurement only. This branch adds no VM change: the k-nucleotide cause ranked
first in `docs/perf-diagnosis-2026-11.md` does not reproduce on this tree, and
the non-string-sweep part of the collector is at parity. Everything below is a
number printed by a probe in this branch or a counter added to a measurement
build.

## Method

* Tree: `knuc` = `integ5` (36a7fb13) + the `9073ddc8` merge, in
  `~/src/LuaJIT-5.4-knuc`. Stock is LuaJIT 2.1 `63c8f1a9` built from
  `.dlcache/bench/luajit-63c8f1a9.tar.gz` by the same Makefile logic, same
  CFLAGS (`-O2 -fomit-frame-pointer`; the two `src/Makefile`s differ only in
  the 5.4 port's `-DLUAJIT_NUMMODE=2`, `lib_utf8` and `lj_i64`).
* `tests/bench/classic/run.py` was changed to interleave the arms
  (stock, ours, puc, stock, ...) instead of running all repetitions of one arm
  first, and `BENCH_PUC=0` skips the PUC arm.
* Stock's collector was given a temporary per-cycle counter
  (`tmp/patch-stock.py`, not committed) so both arms report cycles, `gc.total`,
  `str.num` and `str.mask` at every completed cycle.

## The gap is real; the doc's decomposition is not

Median of 7, interleaved, one job on a pinned x64 box. The numbers are from
the merged tree (`integ5` + `9073ddc8`); the pre-merge run on `integ5` alone
gave the same picture (k-nucleotide 63.2 / 74.1 = 0.85 against 64.8 / 78.0 =
0.83 here, every other row within noise).

| benchmark | stock ms | ours ms | stock/ours |
|---|---:|---:|---:|
| nbody | 6.9 | 7.2 | 1.0 |
| spectral-norm | 15.5 | 16.1 | 1.0 |
| fannkuch-redux | 66.7 | 61.9 | 1.1 |
| binary-trees | 936.8 | 957.9 | 1.0 |
| fasta | 9.8 | 9.4 | 1.0 |
| deltablue | 20665.3 | 22076.8 | 0.9 |
| scimark | 30490.3 | 29462.2 | 1.0 |
| **k-nucleotide** | **64.8** | **78.0** | **0.8** |
| regex-dna | 59.7 | 62.3 | 1.0 |

k-nucleotide is the only >10 % regression on this tree, at 0.83–0.86 across
the runs.

The diagnosis document says the k-nucleotide gap is the collection: "a full GC
pass is ~54 % slower on the same heap" (11.0 vs 16.9 ms) and "the heap is 32 %
larger". Neither reproduces here:

* **A forced full collection at the peak heap is not slower in ours.** A probe
  that runs the workload's stages and calls `collectgarbage("collect")` after
  each, reporting `collectgarbage("count")` before/after and the collect time
  (min of 3, ms):

  | stage | stock heap before → after | stock full GC | ours heap before → after | ours full GC |
  |---|---:|---:|---:|---:|
  | count k=12 (49628 keys) | 4082.2 → 4082.2 KB | 6.9 | 4102.8 → 4102.8 KB | 6.4 |
  | count k=18 (49974 keys) | 7988.0 → 4802.9 KB | 16.6 | 8087.3 → 4826.0 KB | 15.3 |

  Ours' heap is 0.5–1.3 % larger, not 32 %, and the full GC is *faster*.
* **The collector's own cost differs by only +2.8 ms of the +10.9 ms gap.**
  With the same counter on both sides (sum of `lj_gc_step` durations,
  7 runs): stock 15.1 ms over 11 cycles / 1195 steps, ours 17.9 ms over
  8 cycles / 1425 steps. Per step the two are identical (12.7 vs 12.6 µs), so
  the difference is the step *count* (+19 %), not the collector's speed.
* The step budget is dominated by the string sweep (76–87 % of the collector
  time in the Stage 0(b) split), which is out of scope here.

## Where the other 8 ms is

`ours = GC + mutator` and `stock = GC + mutator`, using the same counter:

| arm | total ms | GC ms | mutator ms |
|---|---:|---:|---:|
| stock | 63.98 | 15.13 | 48.9 |
| ours | 73.92 | 17.91 | 56.0 |

So +2.8 ms GC and +7.1 ms mutator. The mutator difference is *not* a VM-wide
slowdown: isolated probes show parity or near-parity in both JIT and
interpreter modes.

| probe (min of 5, ms) | stock -jon | ours -jon | stock -joff | ours -joff |
|---|---:|---:|---:|---:|
| intern 50k fresh strings | 0.12 | 0.12 | 3.77 | 3.76 |
| intern + insert into a table | 1.29 | 1.36 | 3.93 | 3.85 |
| insert 50k pre-interned keys | 0.16 | 0.17 | 1.19 | 1.19 |
| lookup 50k pre-interned keys | 0.36 | 0.39 | 2.47 | 2.58 |
| `string.sub` in a loop | 0.09 | 0.11 | 2.34 | 2.47 |

Table growth, string interning and the string-keyed table path — the three
leads the diagnosis document names — are all at parity.

A stage probe that times each `kfrequency`/`frequency` build in one process
(min of 3, GC on) localises it:

| stage | stock ms | ours ms |
|---|---:|---:|
| k=1 | 1.58 | 1.28 |
| k=2 | 1.30 | 1.46 |
| k=3 | 1.54 | 1.70 |
| k=6 (4091 keys) | 3.50 | 5.37 |
| k=12 (49628 keys) | 10.40 | 17.41 |
| k=18 (49974 keys) | 11.81 | 11.77 |

The gap is concentrated in the mid-size table builds and disappears at k=18,
and the same probe with the collector deferred shows the same work at parity.
So the +7 ms is the collector's *interference* with the mutator, not a
property of the primitives: the collector that runs during k=6/k=12 evicts the
working set of the loop that is building the table.

The cycle trajectories (per completed cycle, counter on both sides) show why
ours interferes more — it collects less often and so carries more live data
through each cycle:

| ours | | stock | |
|---|---|---|---|
| 63.6 KB / 391 str / mask 1023 | | 58.8 KB / 305 str / 1023 | |
| 111.9 / 796 / 2047 | | 63.4 / 329 / 1023 | |
| 138.7 / 308 / 1023 | | 138.2 / 1025 / 2047 | |
| 317.8 / 2356 / 4095 | | 129.7 / 266 / 1023 | |
| 536.4 / 4426 / 8191 | | 303.9 / 2316 / 4095 | |
| 951.1 / 8590 / 16383 | | 345.0 / 2344 / 8191 | |
| 2079.2 / 24415 / 32767 | | 628.5 / 7245 / 8191 | |
| 4193.3 / 50963 / 65535 | | 1762.4 / 16664 / 32767 | |
| | | 3430.3 / 33173 / 65535 | |
| | | 1381.4 / 15258 / 32767 | |
| | | 3563.5 / 33280 / 65535 | |

Ours finishes with 50963 interned strings against stock's 33280 (+53 %), at the
same 65535 mask, and its cycles are 1.6× larger (2.24 ms against 1.37 ms).

## Conclusion

* The diagnosis document's k-nucleotide cause 1 does not reproduce on
  `integ5` + `9073ddc8`: the full collection is not slower in ours, the heap is
  1 % larger rather than 32 %, and the three leads it names (table growth,
  string interning, the string-keyed table path) are at parity in isolation.
* The gap is real and is collector-related, but the collector's own time is
  +2.8 ms of +10.9 ms; the rest is interference that scales with what the
  collector retains between cycles (ours 8 cycles against stock's 11, +53 %
  interned strings at the same table size).
* **No non-string-sweep VM change is supported by this evidence.** The
  collector's non-sweep phases (mark 8 %, atomic 5 %, object sweep ~3 % of its
  time) are at parity per step and total under 3 ms, so even a perfect rewrite
  of them cannot close a 10.9 ms gap. The levers are the string sweep
  (out of scope here) and the cycle/retention policy.

## Next measurement — done: the gap is a policy/phase-alignment effect

The decision experiment was the cycle-policy sweep. Median of 7, interleaved,
one job on the x86_64 test host, k-nucleotide with `collectgarbage("setpause", N)` before the
chunk:

| setpause | ours ms | stock ms | ours/stock |
|---:|---:|---:|---:|
| 100 | 124.71 | 129.63 | 0.96 |
| 133 | 75.17 | 74.56 | 1.01 |
| 150 | 69.66 | 78.38 | **0.89** |
| **200 (default)** | **73.04** | **62.81** | **1.16** |
| 300 | 66.21 | 63.49 | 1.04 |
| 500 | 64.53 | 62.14 | 1.04 |

* The gap **flips sign**: at `setpause=150` ours is 11 % *faster* than stock,
  at 100 it is faster too, and only at the default 200 and above is it slower.
  A fixed handicap in a walk (mark, atomic, object sweep) cannot do that.
* Both curves are non-monotonic (stock has a local maximum at 150, ours at
  200): the cost depends on whether a collection cycle lands in the middle of a
  big table build, i.e. on the alignment of cycle boundaries with the
  workload's phases, not on the speed of any phase.
* With the collector fully deferred the two are within 3.3 % (63.76 against
  61.74 ms), which bounds the mutator-side handicap.

**So the ranked k-nucleotide cause is the collector's cycle timing / its
interference with the workload's phases, not a slow mark or sweep walk.** The
non-sweep phases are at parity per step and total under 3 ms, so a rewrite of
them cannot close a 10.9 ms gap; and the string sweep, which is where the
collector's time actually goes, is out of scope for this task.

No VM change is made on this branch. Changing the default `pause`/`stepmul` is
an operator decision (it is a memory-vs-time trade, and it would move every
workload), so it is reported here rather than applied. The measurements that
would justify a targeted fix, in order:

1. A per-cycle **phase-alignment** census for k-nucleotide: which stage is
   running when each cycle's mark/sweep lands, at `setpause` 150/200/300. That
   names the mechanism (a cycle starting inside the k=12 table build) rather
   than inferring it.
2. The same sweep on the corpus and on the other GC-heavy workloads, to see
   whether ours' optimum is systematically displaced from stock's.
3. If a policy change is wanted, the Stage 0(b) instrument plus this sweep is
   the table to decide it on — with peak RSS as the second axis, since the
   larger pause buys time with memory.
