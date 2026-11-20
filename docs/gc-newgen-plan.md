# A staged plan for a new garbage collector in JITLua-5.4

Design document only. No code changed. Companion to the measurement in
`docs/gc-baseline-2026-11.md` (branch `gcbase`). This document grounds each
stage in those numbers, Pall's LuaJIT 3.0 "new GC" design, and the two prior
implementation attempts, and commits to which stage to build first.

- Baseline: `docs/gc-baseline-2026-11.md` (gcbase worktree, READ ONLY).
- Pall's design: <https://github.com/tarantool/tarantool/wiki/LuaJIT-3.0-new-Garbage-Collector>
  (the missing wiki.luajit.org page, archive copy); original issue text at
  <https://github.com/LuaJIT/LuaJIT/issues/38>.
- Prior attempts: uJIT/LuaVela tutorial copy
  <https://ujit.readthedocs.io/en/latest/public/tut-new-gc.html> and the GMNGC
  prototype report <https://github.com/blueshank-gh/plugin_ljpatch/issues/5>.
- Semantics this fork must keep: `docs/DIFFERENCES.md`.

---

## 1. What a new GC could actually win

The baseline separated wall-time GC cost from pause latency from peak RSS. The
headline: the collector is a **throughput and peak-memory cost on
allocation-churn workloads, not a pause-latency problem.**

Per workload — the upper bound on any GC win is the measured GC share of wall
time, because a perfect collector contributes zero:

| Workload | GC share x64 | GC share arm | Can win | Cannot touch |
|---|---:|---:|---|---|
| binary-trees | **50 %** (473/952 ms) | **45 %** (75/167 ms) | sweep+alloc throughput **and** ~12 MB peak-RSS policy + ~4 MB layout | — the one real target |
| lpeg | 26 % (123/467 ms) | 36 % (44/122 ms) | per-step throughput only | pause policy (deferral *hurts*, -2.6 %/+44 %) |
| k-nucleotide | 24 % | 34 % | string/table churn throughput | — |
| lua-cjson | 13 % | 13 % | per-step throughput | the 126 MB live heap (irreducible) |
| deltablue | 12 % | 14 % | small; real collector work | trace selection (the gap vs stock 2.1) |
| 12 other workloads | < 4 % | < 4 % | nothing | — |

Notes that bound ambition:

- **binary-trees is the one big GC workload.** 473 ms in `lj_gc_step` on x64,
  75 ms on arm; deferring reclaims 22.8 % x64 / 1.8 % arm while doubling peak
  RSS. Peak RSS is 32.4 MB vs PUC 16.4 MB; `setpause=100` closes 12.2 of the
  16 MB gap (76 %), leaving ~4 MB to object size/layout.
- **lpeg's cost is throughput, not tuning.** Default pause/stepmul is already
  the fastest arm; `setpause=100` costs -141.8 % x64 / -132.4 % arm. Only a
  cheaper per-step collector helps here.
- **lua-cjson's 13 % is real work on a 126 MB live heap.** Deferral recovers
  8.5 % x64 / 6.2 % arm, but the 126 MB itself (already under PUC's 158 MB)
  is live data no layout or policy change can shrink.
- **deltablue's GC share is real but its stock gap is trace selection**, not
  GC (`docs/perf-regression-2026-11-17.md`, `docs/DIFFERENCES.md` "Known
  JIT/performance rows"). A GC redesign buys *at most* the 12–14 % share, and
  even that is resistant to deferral (only 1.2/3.1 % recovers), meaning it is
  genuine mark/sweep work, not policy headroom.
- **Pause latency is a solved problem already.** Ours atomic p99 ≤ 2.1 ms
  everywhere; worst single atomic step 7.7 ms (x64 cjson). PUC's step max
  reaches 13.9 ms (x64 binary-trees) / 29.5 ms (arm cjson). There is nothing
  to win on latency; the cost is the *sum* of incremental step durations.
- **The 11 workloads under 4 % and the 5 non-allocating classics** (nbody,
  spectral-norm, fannkuch-redux, fasta, scimark: 0–2 cycles, <0.2 % GC) gain
  nothing from any of this.

**Arithmetic of the prize:** only binary-trees, lpeg, k-nucleotide, lua-cjson,
and (modestly) deltablue justify the work. Summed over the 17-workload suite the
ceiling is roughly (50 % × 0.95 s) + (26 % × 0.47 s) + (24 % × 0.08 s)
+ (13 % × 0.42 s) + (12 % × 23.6 s) ≈ 3.4 s of x64 wall across the whole
suite — dominated by deltablue's absolute seconds despite its low share. Taking
only the three churn workloads (binary-trees, lpeg, k-nucleotide) the ceiling
is ~650 ms x64. No stage below reaches these ceilings; they are upper bounds.

---

## 2. The staged plan

Each stage is separately shippable and measured against the same
`tests/bench/gc-measure.sh` (`x64-box`/`arm-box`, private wrappers that run a
command on a remote x86_64/arm64 test host; one command per arch, the
make line takes `CFLAGS`, never `XCFLAGS=`), on the same pinned boxes.

### Stage 0 — policy and allocator wins, no new collector

Goal: extract the memory and step-overhead wins that do **not** need Pall's
data structures, and add the per-phase instrumentation that de-risks Stages
1–2. Three candidates, two of which ship.

**(a) Default pause/stepmul retune — the ship.** The knobs are `LUAI_GCPAUSE`
and `LUAI_GCMUL` (`src/luaconf.h:102-103`), initialised at
`src/lj_state.c:320-321`, settable at runtime via `collectgarbage("setpause"/
"setstepmul")` (`src/lj_api.c:1974/1978`). The baseline brackets the space:

| binary-trees x64 | pause/stepmul | wall | peak RSS |
|---|---:|---:|---:|
| default | 200/200 | 952 ms | 32.4 MB |
| defer | 1000/200 | 735 ms (-22.8 %) | 67.1 MB (+103 %) |
| pause100 | 100/200 | 1517 ms (+59 %) | 20.2 MB (-12.2 MB, 76 % of gap) |

The baseline proves the memory gap is 76 % policy, but `setpause=100` *alone*
buys that memory by running ~2× the cycles and paying +59 % wall. The
hypothesis the Stage 0 patch tests is that **pairing a lower pause with a
higher stepmul** (fewer, larger steps within the non-binding 2 ms latency
budget) recovers most of the memory at a fraction of the +59 % cost, because
the per-step *fixed* overhead (debt accounting, `lj_gc_step` entry, the
`GCSTEPSIZE` granularity — `src/lj_gc.c:749-878`) shrinks when stepmul grows.

Estimate (to confirm by sweep, not assumed): on binary-trees, land ~20–24 MB
RSS (≈8–11 of the 12 MB policy gap) at ≤ 10 % wall cost, matching PUC memory
at a small time price; zero effect on the 12 sub-4 % workloads and on lpeg
(whose policy is already time-optimal — the one place the retune must
*regress-proof* with an explicit lpeg check). The required measurement: a
sweep of `pause ∈ {100, 133, 150, 200}` × `stepmul ∈ {200, 300, 400, 500}` on
binary-trees and lpeg, both arches. This is a one-constant (or two-constant)
patch with reproducible, wall+peak-RSS evidence.

**DECIDED 2026-11-19: the default pause is 300, and memory is the opt-in mode.**
The hypothesis above (pairing a *lower* pause with a higher stepmul to buy RSS)
was tested and rejected: `setstepmul=400` alone leaves k-nucleotide at 0.92 of
stock and lowering the pause costs time everywhere, while *raising* the pause
buys time on the workloads that matter. The default is therefore `pause 300 /
stepmul 200` (`LUAI_GCPAUSE` in `src/luaconf.h`) and the RSS-first setting
became the opt-in `LUAJIT_GC=memory` / `-G memory` mode (pause 100 / stepmul
200). Measured with `tests/bench/classic/run.py` and `tests/bench/gc_measure.py`
(median of 7, interleaved, one box per arch, `-jon`; corpus rows are
ours-200 vs ours-300 because a fork-built module will not load in stock):

| workload | stock ms / MB | speed 200 ms / MB | speed 300 ms / MB | memory ms / MB |
|---|---|---|---|---|
| nbody | 9.2 / 12.0 | 11.3 / 12.0 | 11.3 / 12.0 | 11.4 / 12.0 |
| spectral-norm | 22.1 / 12.0 | 22.0 / 12.0 | 24.1 / 12.0 | 24.2 / 12.0 |
| fannkuch-redux | 70.1 / 12.0 | 65.9 / 12.0 | 65.9 / 12.0 | 65.9 / 12.0 |
| binary-trees | 936.8 / 32.6 | 967.8 / 28.9 | **855.4 / 38.7** | 1526.6 / 19.8 |
| fasta | 13.5 / 12.0 | 13.5 / 12.0 | 13.5 / 12.0 | 13.5 / 12.0 |
| deltablue | 19766.5 / 12.0 | 22225.0 / 12.0 | 21882.9 / 12.0 | 26588.1 / 12.0 |
| scimark | 30593.8 / 12.0 | 29542.9 / 12.0 | 29594.7 / 12.0 | 29530.0 / 12.0 |
| k-nucleotide | 66.3 / 12.0 | 76.9 / 12.0 | **70.4 / 12.0** | 129.8 / 12.0 |
| regex-dna | 61.7 / 12.0 | 65.9 / 12.0 | 66.0 / 12.0 | 68.0 / 12.0 |
| lpeg | (no stock arm) | 464.3 / 16.7 | 462.6 / 19.6 | 1121.8 / 15.3 |
| lua-cjson | (no stock arm) | 425.5 / 126.5 | 407.8 / 127.5 | 524.5 / 127.0 |

arm64 test host (median of 11, one box; the run was taken at load 2.3 → 7.8, so
the small rows carry spread — see `docs/notes/knuc-open-2026-11-19.md`):

| workload | stock ms / MB | speed 200 ms / MB | speed 300 ms / MB |
|---|---|---|---|
| binary-trees | 169.9 / 32.6 | 170.5 / 29.0 | **158.8 / 37.2** |
| k-nucleotide | 28.2 / 12.4 | 42.0 / 12.4 | **30.5 / 12.4** |
| deltablue | 3504.3 / 12.4 | 3350.3 / 12.4 | 3250.1 / 12.4 |
| scimark | 25335.4 / 12.4 | 26335.1 / 12.4 | 26119.2 / 12.4 |
| lpeg | (no stock arm) | 132.3 / 16.1 | 130.0 / 19.3 |
| lua-cjson | (no stock arm) | 250.0 / 125.6 | **233.9 / 125.8** |
| nbody / spectral / fannkuch / fasta / regex-dna | — | flat | flat |

Read-out: 300 is never worse than 200 by more than noise on either arch, it
closes most of the k-nucleotide gap (0.86 → 0.94 x86_64; 0.67 → 0.92 arm64) and
makes binary-trees faster than stock (1.09 / 1.07), at +34% / +15% peak RSS on
binary-trees and +17% on lpeg. The memory mode is unchanged (pause 100 /
stepmul 200) and still the RSS-first setting.

**(b) Per-phase GC instrumentation — the enabler.** The `-DLUAJIT_GC_STATS`
block (`src/lj_gc.c:33-113` on gcbase) already yields steps/cycles/atomic
durations and log2 pause histograms, but **no mark-vs-sweep-string-vs-sweep-
vs-finalize split**. The baseline's "ours GC ms" is the sum over all phases,
so no stage below can estimate its share of the win without a phase breakdown.
Stage 0 adds per-phase counters (propagate, sweepstring, sweep, finalize)
plus a "objects scanned-live vs objects freed" count to that block. This is a
measurement-only change (compiled out by default) whose output *decides*
whether Stage 1 targets sweep, allocation, or marking.

**(c) lj_alloc tuning and "faster sweep" — deferred, not shipped first.**
`src/lj_alloc.c` is a heavily customised dlmalloc
(`src/lj_alloc.c:1-21`, tunables at `:39-44`: `DEFAULT_GRANULARITY` 128 KB,
`DEFAULT_TRIM_THRESHOLD` 2 MB, `DEFAULT_MMAP_THRESHOLD` 128 KB). Sweep
(`src/lj_gc.c:420`, `gc_sweepstr` `:450`) walks every object per cycle. But
the baseline does **not** separate dlmalloc latency (which sits in mutator
time, not "GC ms") from mark/sweep/atomic time, so neither candidate can be
estimated from today's numbers. GMNGC's report is the cautionary prior: a
half-done allocator loses -16 % table allocation and +7 % baseline heap, and
its author flags "time-based UAF & UB failures" throughout. Do **not** build
an arena allocator as a bolt-on "faster malloc" before the bitmaps exist (see
Stage 1). The named measurement to reopen (c): rebuild with
`LUAJIT_USE_SYSMALLOC` and diff binary-trees wall — if sysmalloc is not
faster, dlmalloc tuning is not the lever.

**Stage 0 exit criterion:** binary-trees peak RSS drops to ≤ 24 MB x64 with
≤ 10 % wall regressions on binary-trees and ≤ 2 % on lpeg, and the phase
breakdown pinpoints the dominant phase for Stage 1.

### Stage 1 — arenas plus mark bitmaps for ONE object class (tables)

Goal: Pall's arena + block/mark-bitmap machinery for **`GCtab` only**, keeping
the current tri-color phases, the inline `marked` byte, the existing barriers,
and the JIT untouched. Deliberately a **parallel** bitmap (the inline `marked`
byte stays authoritative) so the stage cannot break the mark/barrier contract
— the bitmap accelerates sweep and allocation, it does not yet *replace* the
colour bits. That replacement is Stage 2.

**Why tables.** binary-trees — the largest measured win (50 % x64 / 45 % arm,
110 cycles) — is *pure* table allocation; each node is a `GCtab`. lpeg (26/36)
and lua-cjson (13) are table+string churn. Strings already have a segregated
path (`lj_str.c` intern hash, `gc_sweepstr` `src/lj_gc.c:450`, swept per
chain). Tables are the churning class with the worst current representation
(the shared root list, `lj_mem_newgco` `src/lj_gc.c:967`). Evidence for the
pick: binary-trees' 50 % share and its near-100 % death rate per cycle.

**What changes.**

- Allocation: `lj_mem_newgco` (`src/lj_gc.c:967`) special-cases `~LJ_TTAB` to
  bump-allocate `sizeof(GCtab)` (42-ish bytes + `asize*TValue`) cells from a
  table arena, set the block bit, bump the frontier — no dlmalloc `malloc`,
  no `nextgc` list link. `lj_tab_free` (the `LJ_TTAB` entry of the
  `gc_freefunc` table, `src/lj_gc.c:396-413`) and `lj_tab.c` allocators
  (`lj_tab_new`, `lj_tab_resize`, `lj_tab_free`) route through the arena.
  `g->gc.total` accounting (`src/lj_gc.c:952`, `:967`) is unchanged in
  *value*, just sourced from block sizes.
- New file `src/lj_arena.c`/`.h`: arena carve (64 KB–1 MB, naturally aligned),
  cell/block indexing by address mask, block+mark bitmaps in the 1/64 metadata
  area, and the two word-wise sweep transforms from Pall:
  major sweep `block' = block & mark, mark' = block ^ mark`; (minor sweep
  `mark' = block | mark` is reserved for Stage 3, not wired yet).
- Mark: `gc_mark` (`src/lj_gc.c:60`) and `gray2black`/`makewhite`
  (`src/lj_gc.h:32-44`) additionally set/clear the table's bitmap bit — the
  inline byte and the bitmap are written together, so a drift is a UAF. Sweep
  (`gc_sweep` `:420`) stays authoritative via the inline byte for *everything
  else*; tables are swept by the bitmap with the dead-block free list still
  calling `lj_tab_free` per dead object.

**Invariants that must hold (unchanged behaviour, cited):**

1. **Non-moving.** Arena cells are carved once; a table's address never
   changes. This is exactly Pall's non-copying constraint and it is what keeps
   the JIT's embedded `IR_KGC` constants, the 47-bit tagged `GCRef` layout
   (`src/lj_obj.h:54-60`), the C API pointers, and FFI cdata valid. No
   compaction anywhere.
2. **Weak/ephemeron clearing.** `gc_traverse_tab` (`src/lj_gc.c:181`),
   `gc_clearweak` (`:494`) and the 5.4 boxed-int64 rule (ADR-001b: a boxed
   integer is a value, always marked — `src/lj_gc.c:196-235`) are untouched;
   weak tables still clear identically. `tests/d54/weak_*.lua` stays green.
3. **Finalizer order.** userdata separation/finalization (`atomic` `:642`,
   `gc_finalize` `:559`, `lj_gc_separateudata` `:149`) and the in-progress
   `__gc`-for-tables work (branch `tablegc`) run outside the table arena; the
   `GCSfinalize` ordering is unaltered.
4. **The JIT's GC check and sinking are not touched.** `asm_gc_check`
   (`src/lj_asm_x86.h:3009`) still reads `gc.total` vs `gc.threshold`; the
   table barrier `asm_tbar` (`:2115`) still tests the inline `marked` byte —
   Stage 1 keeps that byte present and correct, so no JIT change is needed.
   `lj_opt_sink.c` treats `IR_TBAR` as an ordinary load (`src/lj_opt_sink.c:89`)
   and `lj_opt_fold.c` still folds `TBAR TNEW/TDUP` away
   (`src/lj_opt_fold.c:2485-2501`); both are unaffected.
5. **`collectgarbage("count"/"step"/"collect")`.** The byte accounting stays
   consistent; arena totals must agree with `gc.total` to the block.

**Tests that must go red first.**

- New arena-accounting unit test: `collectgarbage("count")` equals the sum of
  allocated block sizes within the arena, and returns to baseline after a full
  collect (no leak, no over-free).
- New mark/bitmap-coherence stress test: a loop that allocates+frees tables
  across cycles and asserts a table's lifetime matches its bitmap/inline-byte
  state (this is the UAF trap GMNGC fell into).
- Existing regressions that must stay green: `tests/d54/weak_*.lua`
  (weak-table JIT loop), `tests/d54/close_*.lua` (to-be-closed), udata
  `__gc` order tests, and the full harness modes A+B (165 PASS / 0 FAIL /
  9 XFAIL).

**Expected gain and risk.** Upside is bounded by the table-churning
workloads' GC share; realistically Stage 1 removes the *sweep-scan and
malloc-free* components of that share, not the traversal (which must still
read table contents) or the finalize phase. Realistic estimate: 5–15 % on
binary-trees, ≤ 5 % on lpeg and lua-cjson, 0 elsewhere — but this is a range,
not a number, until the Stage 0(b) phase split says how much of the 473 ms
x64 binary-trees GC is sweep+alloc vs mark+atomic. Risk: medium. The bitmap
adds ≤ 1.5 % memory and a coherence bug is UAF-class; both are contained by
keeping the inline byte authoritative and by the accounting tests.

**Stage 1 exit criterion:** binary-trees wall improves ≥ 5 % at unchanged
peak RSS, harness A+B green, and no GC correctness regression; paired with
the Stage 0 policy win the binary-trees memory+time story is the shippable
proof.

### Stage 2 — quad-color and the new barrier fast path

Goal: move white/black into the bitmap and add Pall's inline **gray** bit, so
the write-barrier fast path checks a single gray bit and no longer reads any
mark metadata. This is what makes steady-state barriers nearly free.

**Exact consequences for the JIT's barrier emission.**

- The barrier test inverts polarity. Today `asm_tbar` (`src/lj_asm_x86.h:2115`)
  emits `TEST byte [tab+offsetof(GCtab,marked)], LJ_GC_BLACK` and calls
  `lj_gc_barrierback` when black (a rare event). The interpreter macro
  `lj_gc_anybarriert` / `lj_gc_barriert` (`src/lj_gc.h:98-105`) checks
  `isblack`. Stage 2 replaces "is black?" with "is the inline gray bit
  clear?" — and because a newly allocated traversable object is *light-gray*
  (gray bit set, bitmap white), the common-case branch is the *fall-through*:
  no bitmap access, no call.
- `asm_tbar` and `asm_obar` are re-emitted in all five backends
  (`lj_asm_x86.h:2115/2130`, `lj_asm_arm64.h:1447/1464`,
  `lj_asm_arm.h:1382/1402`, `lj_asm_ppc.h:1253/1270`,
  `lj_asm_mips.h:1688/1704`); `lj_gc_barrierf` / `lj_gc_barrieruv`
  (`src/lj_gc.c:891/906`) and the `lj_gc_objbarriert`/`lj_gc_objbarrier`
  macros (`src/lj_gc.h:103-111`) rewrite the slow path to test a bitmap word
  and push onto a sequential store buffer (SSB).
- `GCHeader` (`src/lj_obj.h:63`) re-means the `marked` byte: gray bit inline;
  `FINALIZED`, `WEAKKEY/VAL`, `FIXED/SFIXED`, `CDATA_FIN` stay inline; white/
  black move out. For tables (already in arenas from Stage 1) the 8-byte
  `nextgc` link becomes dead — 8 bytes/table saved, tail of the ~4 MB layout
  gap the baseline attributed to object size.
- Sinking/folding: `lj_opt_fold.c:2485` treats barriers as CSE-able, and
  `TBAR TNEW/TDUP` folds away except across a GC step (`:2495-2501`). Those
  rules hold, but the fold *reason* shifts to "new tables are light-gray →
  barrier falls through"; the `gcstep_barrier` guard stays.
- `gc_mark`/`white2gray`/`gray2black`/`makewhite`/`iswhite`/`isblack`
  (`src/lj_gc.h:27-44`, `src/lj_gc.c:60`) become bitmap+gray-bit operations.

**Invariants:** all of Stage 1's, plus the quad-color transition table
(light-gray → dark-gray on mark → black on traverse → white on sweep) is
exactly Pall's; the two-whites flip maps onto the differential `(block,mark)`
pair rather than the old `currentwhite ^ LJ_GC_WHITES` byte flip.

**Gain/risk:** this is where the JIT barrier cost — already cheap — drops
toward zero and the mark/sweep metadata stops polluting object data caches.
The win on this harness is *expected to be modest* (barriers are already
2–3 instructions and rarely taken); the stage earns its cost on JIT-heavy
table-mutation code, which the classic/corpus set only mildly exercises.
Risk: high — it touches every backend and the colour contract at once; it
must land only after Stage 1's coherence tests are in place.

### Stage 3 — generational (sticky marks) with 5.4 semantics

Goal: Pall's sticky-mark minor/major scheme (minor sweep keeps survivors
black: `block' = block & mark, mark' = block | mark`; major sweep flips:
`mark' = block ^ mark`), with automatic mode switch, mapped onto the 5.4
`collectgarbage` surface.

**5.4 parameter semantics** (the current `collectgarbage("generational")`
only sets a `gcmode` flag and does not install a collector —
`src/lib_base.c:537`, noted in the baseline): `"generational"` enables minor
collections, `"incremental"` forces major-only, both must return the previous
mode string; `"setpause"`/`"setstepmul"` feed the threshold in both modes,
and `"step"`/`K`/`"collect"` drive a bounded number of steps or a full major
cycle.

**Quantitative caveat:** the baseline's PUC-generational arm is within noise
of PUC-incremental on all 17 workloads, so Stage 3 has **no measured payoff
on `gc-measure.sh`**. Its value is request/response and long-lived-server
workloads the harness does not measure. It should be justified by a *new*
measurement (a request-loop or `k-nucleotide`-style young-death microbench),
not by the current suite. Rank it behind everything.

---

## 3. Recommendation

**Build Stage 0(a) first — the policy retune — together with Stage 0(b)'s
phase instrumentation.** This is the smallest prototype with a measured gain:
it recovers most of the binary-trees 2×-PUC peak-RSS gap (a reproducible wall
+peak-RSS win with the same `gc-measure.sh`), at near-zero risk, and the
per-phase numbers it produces decide whether Stage 1 attacks sweep, alloc, or
mark. It does not touch the collector, so it ships without touching any of the
DIFFERENCES invariants.

**Build Stage 1 (table arenas + bitmap) next, and only on the strength of
Stage 0's phase split.** It is the one piece of Pall's design whose measured
gain (sweep + allocation on churn) justifies its risk, and it is deliberately
scoped to parallel bitmaps so it cannot break the mark/barrier contract.

**Do not build, now or until proven otherwise:**

- **Generational collect (Stage 3) at all.** The baseline shows it is
  indistinguishable from incremental on this harness; it needs a different
  workload to justify itself.
- **The fit allocator, SSB, gray queue, and huge-block machinery** (the tail
  of Stage 2). These are Pall's complexity budget, not the measured win; build
  them only if Stage 1's phase data shows allocation/sweep, and only after the
  bump allocator's fragmentation actually matters.
- **A standalone arena "faster malloc" without bitmaps.** GMNGC's -16 % table
  allocation and +7 % baseline heap, plus its admitted UAF/UB instability,
  show the allocator and the bitmap must land together or not at all.

---

## 4. Questions the baseline does not answer

Each is a named measurement, not a conjecture:

1. **Phase split of "ours GC ms".** How much of binary-trees' 473 ms x64 is
   propagate vs sweepstring vs sweep vs atomic/finalize? → Stage 0(b)
   per-phase counters. This turns every Stage 1 estimate into a number.
2. **Mutator allocation cost vs step cost.** Is dlmalloc's `malloc`/`free`
   (in mutator time, invisible today) or the sweep scan the larger term? →
   `LUAJIT_USE_SYSMALLOC` A/B on binary-trees.
3. **The (pause, stepmul) knee on binary-trees + lpeg.** The baseline only
   has three points (200/200, 1000/200, 100/200). → the `pause × stepmul`
   sweep from Stage 0(a).
4. **Per-object-size breakdown of that ~4 MB layout gap.** Which fields
   (the 8-byte `nextgc` in every object under GC64, TValue size, padding)?
   → a size histogram of live objects at binary-trees peak; it tells us how
   much of the gap Stage 2's `nextgc` removal actually recovers.
5. **Whether a generational mode is ever worth it here.** → a young-death
   microbench outside `gc-measure.sh` before Stage 3 is scheduled.
