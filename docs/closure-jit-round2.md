# Closure-jit round 2: weak-table loop hang

Round 2 replaced 32068a54's blanket record-time abort (reverted in 3a59e63b
and f759fcde) with the mechanism Fable measured. Implementation:

1. Dead loop-head temps are restored as nil. `lj_snap_purge` marks dead slots
   with `TREF_PURGED`; `snapshot_slots` emits `SNAP_NIL` entries (below and
   above the snapshot's live range); `lj_snap_restore`, side-trace replay and
   the GC step clear them. The measured stale slot is the TGETB temp in the
   first slot above the loop's live top (`LOOP A`), i.e. above `nslots`, so a
   loop-stop purge also marks slots above maxslot whose recorded value is not
   an `SLOAD` (temps); SLOAD slots are live locals and are left alone.
2. The GC step clears the `SNAP_NIL` stack slots in the trace before calling
   `lj_gc_step_jit`, using the trace's `REF_BASE` register (`RID_BASE` is only
   valid in exit stubs). Implemented for arm64 and x64, the gated targets.
3. A trace that indexes a table weak at record time (`JIT_F_WEAKTRACE`) keeps
   its allocating IR (`ir_isalloc`) past both DCE layers, so the existing loop
   GC check has heap growth to trigger on. Traces without weak tables keep full
   DCE.
4. `rec_tabguard` emits a runtime guard per indexed table operand: metatable
   pointer equality and the `__mode` absence bit in `mt->nomm` (equality with
   the record-time value; for a strong table the bit is forced set at record
   time). Guard misses exit normally and re-specialize; weak tables stay
   compiled.

Remaining boundary: a loop with no allocation at all and only a weak-table
read cannot make GC progress; PUC 5.4 hangs on that shape too. Documented in
`docs/DIFFERENCES.md`.

Measurement note: the earlier session read the debug slot as bytecode slot 3
and concluded it was below `nslots=5`. In snapshot coordinates it is the first
slot above the live range (J slot `nslots`); both arches agree.

## Round 3: C-side GC clearing, 64-bit pak, regression test

The GC-check clearing moved out of asm entirely. The asm slow path is skipped
when gc.total < gc.threshold, so no allocator action may be emitted there; the
old code called ra_alloc1(REF_BASE) inside it (a remat load at jit_base). The
observable regression was arm `i64_02_jit.lua [B@2]` (deterministic wrong int64
values), red on the asm variants and green after.

`lj_gc_step_jit` now takes a 64-bit pak on GC64 targets (traceno 16 b, exit
snapshot 16 b, step count 32 b), loaded as one emit_loadu64 into the existing
ASMREF_TMP2 register. The C side finds the trace by traceno (not g->vmstate:
arm64 stores 0 on trace), clears the SNAP_NIL slots of T->snap[snapno] relative
to jit_base, and returns early when the snapshot has no SNAP_NIL. 32-bit
backends keep the old 2-arg call with no clearing; snapshot_slots asserts that
such a target never emits SNAP_NIL. Built/gated targets: x64 and arm64.

A weak shape with SNAP_NIL under register pressure does not go red: in the
inspected -jdump=+rs the remat and its uses both sit inside the slow path, and
the body does not need REF_BASE after the check. `weak_maxsnap.lua` sets
maxsnap/maxtrace above the defaults and forces a loop snapshot index > 511.
