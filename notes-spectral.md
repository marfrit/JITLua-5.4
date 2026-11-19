# SPECTRAL breadcrumbs (2026-11-19)

Worktree ~/src/LuaJIT-5.4-spectral, branch spectral, integ5 merged.
Brief: ~/tmp/ds-spectral.txt.

## DONE: pcall/xpcall JIT restoration (commits 838e414e, 87416a0a, 5a3e7d7e)
- New IRFL_THREAD_CCALLNEST (offsetof(lua_State, ccallnest)) in lj_ir.h.
- recff_pcall/recff_xpcall: emit FLOAD ccallnest + IR_EQ guard (==0) instead
  of aborting. Top-level pcall/xpcall compile; nested/recursive exit to the
  interpreter. b5_pcall: pcall 150->44ms, xpcall 150->2.9ms (x64, 2M iters).
- err_04, gc_03, calls.lua B/R green (x64). Gates NOT yet re-run.

## TODO
- Run ci-box + ci-local --sanitizers-only on x64 and arm64.
- Spectral reduction: measure stock vs ours (interleaved median 7, x64+arm),
  then -jdump=+rs of the Av/Atv inner loop with
  LUA_PATH="$REPO/src/?.lua;;" (stock "$REPO/tmp/stock-luajit/src/?.lua;;"),
  run from .dlcache/bench/src. Earlier x64: stock 15.4ms, ours 16.0ms (~4%).
  Name the added IR (int32 CONVs, overflow guards) and reduce (lj_opt_fold.c,
  lj_opt_narrow.c, lj_asm_x86.h). Tests for any fold/narrowing: 2^31-1, 2^31,
  -2^31, 2^53, 2^63-1, mixed int/float, // and % negatives; mode B opt 0-3.

## -jdump finding CORRECTED (x64; -jdump output is on STDOUT)
Stock 2.1 DOES emit the `FLOAD tab.meta` + `EQ NULL` guard for the integer-key
store too (full trace 1: 0009/0010, after the array AREF). So the guard is NOT
an ours-only addition and (1)'s premise was wrong. The real trace-1 deltas:
ours orders the guard before the array access and uses SLOAD flags `RI`/`TI`
where stock uses `CRI`/`CI`; ours emits ~2x the traces (68 vs 36 dump lines).
Measurement is ~4%, below the >10% row.

## old (wrong) -jdump note
Trace 1 (init loop `for i=1,N do u[i]=1 end`): ours adds
`FLOAD tab.meta` + `EQ NULL` (the 5.4 integer-key metatable guard before a raw
store) and different SLOAD type flags (ours RI/TI vs stock CRI/CI); stock has
no metatable guard. More traces (ours 68 vs stock 36 dump lines).
Measurement x64: stock 15.4ms vs ours 16.0ms (~4%, below the >10% row).
Reduction not done. Candidate: fold/hoist the tab.meta NULL guard when the
recorder already knows the table has no metatable.

## pcall/xpcall trace recording — penlight cause (2026-11-19)
Re-applied the recording (87416a0a) and ran `sh tests/corpus-ext/run.sh penlight`
under -jon and -jon+GC-stress: `tests/test-pretty.lua` fails with
"LUA: C stack overflow" at `./lua/pl/pretty.lua:281` (inside a `for ... in`
loop that calls pcall) while -joff is SAME. So the top-level-only
`ccallnest == 0` guard does not count the nesting of a pcall that a trace
enters; the counter leaks/overflows and the interpreter's bound fires. The
proper fix is the trace-level counter with an increment AND a matching
decrement (and an exit near the limit), which was not implemented. The
recording is reverted again; only the benchmark (838e414e) and this note stay.

## KEEP (compaction 2026-11-19 06:36)
- Worktree ~/src/LuaJIT-5.4-spectral, branch spectral (integ5 merged, 2aad38af).
- Commits to keep: a7a617df (spectral-measure.py + notes), f6ce1d07 (corrected
  tab.meta finding), 1d982c7d (penlight cause note), 838e414e (b5_pcall bench).
- Reverted recording: 87416a0a ("jit: record top-level pcall/xpcall in traces
  again") - re-apply with `git revert --no-edit <its revert>` if needed.
- Penlight cause: tests/test-pretty.lua, pl/pretty.lua:281 (pcall inside a
  `for ... in` loop) -> "LUA: C stack overflow" under -jon with the
  `ccallnest == 0` guard; the guard does not count the nesting. Prerequisite
  for recording pcall/xpcall: a trace-level counter with increment AND
  decrement (and exit near the limit).
- Gates: `sh tests/ci-box.sh` AND `sh tests/ci-local.sh --sanitizers-only`,
  both arches. Only x64-box/arm-box wrappers; NEVER build or test on pica.
  X64_BOX_HOST only for A/B benchmarks on one box.
- Commit tagline: "Implemented by DeepSeek-4.1-Flash (cloud); briefed by
  Claude." + Co-Authored-By lines (noreply@example.invalid). Tests first, then
  src, then docs.
- (1) result: stock 2.1 emits the same tab.meta guard; real delta is SLOAD
  flags (ours RI/TI vs stock CRI/CI) + ~2x traces; gap ~4%, no reduction done.

## Trace-level pcall/xpcall counter — REASONING (before coding)
Goal: a recorded pcall/xpcall increments L->ccallnest before entering the
protected call and exactly one decrement happens on every path.

Increment: recff_pcall/recff_xpcall, before lj_record_call:
  th = IR_LREF IRT_THREAD; cn = FLOAD th IRFL_THREAD_CCALLNEST
  guard IR_LT(cn, LJ_MAX_XLEVEL)   (exit to the interpreter at/over the limit;
                                    the interpreter's lj_ffh_pcall raises
                                    "C stack overflow", matching -joff depth 200)
  FSTORE IRFL_THREAD_CCALLNEST = cn+1
  ... lj_record_call ...
The guard is on the PRE-increment value so the trace enters at cn=199 -> 200
exactly like the interpreter fast path (which tests ccallnest >= 200 before
incrementing).

Decrement (the crux): exactly one of these must run per increment.
| path                                             | decrement site |
|--------------------------------------------------|----------------|
| trace returns normally from the pcall frame      | recorder, in the FRAME_PCALL return handling (rec_ret) - emit FSTORE cn-1 |
| pcalled function errors inside the trace         | trace exits; interpreter vm_unwind_ff_eh decrements (the FSTORE already bumped memory) |
| side exit inside the protected region            | trace exits; the pcall frame is still live, so interpreter vm_returnp/vm_unwind_ff_eh decrements when it returns |
| trace exits after the pcall returned normally    | already decremented by the recorder on the normal return; interpreter must NOT decrement again (the frame is gone) |
So the recorder emits the decrement only on the post-call continuation of the
trace (the path that is reached iff the call returned inside the trace); the
interpreter's decrements cover every exit before that point. Need to verify in
lj_record.c rec_ret / rec_call_setup how a FRAME_PCALL frame's return is
recorded and whether the continuation is on the same trace (no exit) - if the
pcall frame return always exits the trace, the decrement belongs in the exit
handler instead and the whole scheme must be re-thought.

RED tests (first): minimised test-pretty (pcall in a for-in loop, 1e5 iters,
-jon); recursive pcall depth probe under -jon == -joff (200); error inside the
pcalled function from a trace; side exit inside the protected region;
coroutine.wrap inside pcall. Modes A/B at -O0..-O3 and GC stress.
Then b5_pcall before/after, penlight corpus-ext SAME (-jon, -jon+gcs), gates.
