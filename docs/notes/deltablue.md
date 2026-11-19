# deltablue performance: the trace-census delta was layout noise

Goal from the task: close the deltablue JIT gap (stock/ours 0.86 measured at
`integ5`/`36a7fb13`) by fixing the trace-recorder thrash that the perfdiag
branch named as cause 1 (`docs/perf-diagnosis-2026-11.md`), or by the policy
change sketched for `rec_loop_interp`'s `LLEAVE` branch.

Branch `deltablue`; worktree `~/src/LuaJIT-5.4-deltablue`. The task said to
merge main first; main had moved on to `f51a7608` (guardperf merged), and that
merge is what closed the gap. No source change was needed or made.

## Result

Merged tree, one pinned x64 box, interleaved, all deltablue runs:

| job | options | stock/ours | note |
|---|---|---|---|
| classic set, median of 9 | `-jon` | **0.964** | acceptance job |
| full classic set, median of 7 | `-jon` | **1.018** | |
| final job, median of 7 | `-jon` | **1.025** | |
| final job, median of 7 | `-joff` | **0.989** | interpreter parity |

Trace census on the merged tree (`-jon -jv`, one layout): ours 274 starts /
92 aborts / 1 blacklist, stock 302 / 141 / 12. Ours now aborts **fewer** times
than stock, where the pre-merge tree aborted more.

Classic set on the merged tree: nbody 0.998, spectral-norm 0.499 (separate
regression, see below), fannkuch 1.000, binary-trees 1.000, fasta 0.999,
deltablue 1.018, scimark 1.061, k-nucleotide 1.002, regex-dna 1.001.

## What the investigation showed

**The bytecode is identical.** `luajit -bl deltablue-locals.lua` for stock 2.1
and the fork differs only in the printed jump *targets*; the instructions
(opcode, A, B, D) match. The display difference is a cosmetic bug in
`src/jit/bc.lua` `bcline()`: `local d = ins >> 16` sign-extends the 32-bit
`funcbc` result in dual-number mode, so `pc+d-0x7fff` prints e.g.
`=> 281474976645127` instead of `=> 0007`. The VM is unaffected. So the
"parser emits different bytecode" candidate is ruled out.

**The recorder's loop code is identical.** `innerloopleft`, `rec_loop_interp`,
`rec_loop_jit`, `rec_for`, `rec_for_iter`, `rec_for_loop`, `rec_for_check`,
`fori_load/conv/arg` are byte-identical to the pinned stock 2.1 source
(`.dlcache/bench/luajit-63c8f1a9.tar.gz`). The planned `innerloopleft` gate in
the `LLEAVE` branch was therefore never the fix for a code difference.

**The `-jv` abort census is not a stable property.** It is a chaotic function
of the heap layout: the hotcount is hashed on the bytecode *address*
(`hotcount_get`, `lj_dispatch.h`) and the penalty/blacklist PRNG stream shifts
with the allocator. With a fixed PRNG seed (`-DLUAJIT_SECURITY_PRNG=0`) each
build is deterministic, but perturbing the heap (a `LUA_INIT` that allocates
before the script is loaded) or even just the job path length moves the census
completely:

| arm | aborts / blacklists across four layouts |
|---|---|
| stock | 218/27, 189/18, 86/0, 149/1 |
| fork  | 240/30, 134/1, 234/22, 88/1 |

`tests/bench/db-perturb.sh` shows this. So "LINNER 41 vs 16, LLEAVE 17 vs 8,
11x at :700" was one layout sample, not a reproducible defect, and the
proposed policy change would have chased noise. It was not applied.

**The stable cost was the weak-table guard, and main already fixed it.**
`rec_tabguard` emitted, per indexed table operand, `FLOAD tab.meta; EQ meta,
{Class}` in addition to the `__index` chain's own `FLOAD tab.meta; NE NULL` —
the class idiom paid two guards on one metatable load. A clean A/B (one
binary, fixed seed, a runtime knob to skip the guard) measured **4 % of the
whole deltablue run**; the hoisted `__mode` lookup itself did not cost.
`docs/notes/guardperf.md` describes the fix that landed on main: the
metamethod lookup guards the metatable identity (`EQ ktab(mt)`) and looks the
metamethod up in the constant metatable, so the folder CSEs the two guards and
the loop over many receivers of one class hoists the rest. Merging that
(`f51a7608`) is what moved deltablue from 0.878-0.906 to >= 0.96.

## Left open

- **spectral-norm 0.499** in the classic set is a separate regression, not a
  deltablue one; it has its own branch and `docs/notes/spectral.md`.
- **`src/jit/bc.lua` jump-target display** prints sign-extended targets
  (`=> 281474976645127`). Cosmetic, but it makes `-bl` diffs useless; mask
  `d` to 16 bits.
- **Census comparisons need a fixed layout.** Any future loop-abort work must
  build stock and the fork in one job, with a fixed PRNG seed and the same job
  path length, before a delta means anything; single-run `-jv` censuses are
  not evidence.
- The `-Ohotloop=20` / `-Ohotexit=3,tryside=6` tuning that recovered ~13 points
  at `14cbb389` was not revisited: after the guard fix there is no gap left to
  recover on deltablue.

## Scripts

- `tests/bench/classic/run-interleaved.py` — the acceptance runner: classic
  set, arms interleaved per repetition, median of `BENCH_REPS`.
- `tests/bench/deltablue-final.sh` — census + interleaved timing, both arms.
- `tests/bench/db-det.sh` — deterministic (fixed seed) census of both arms.
- `tests/bench/db-perturb.sh` — the layout-sensitivity demonstration.
