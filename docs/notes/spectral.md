# pcall/xpcall in traces: the nesting counter

Notes for the trace-level pcall/xpcall counter (`lj_record_ccallnest`,
`rec_ccallnest_flush` in `src/lj_record.c`). The spectral-norm measurement that
started this branch is at the end.

## Background

The 5.4 bound on nested pcall/xpcall is counted in `L->ccallnest` by the
interpreter fast paths (x64 and arm64). A compiled pcall has to keep the same
counter exact, or the bound fires too early (leak) or pcall stops working on
the thread (underflow). The counter is a field of the thread, not a stack slot,
so no snapshot restores it: memory has to be right for every state a trace can
leave to.

A first version guarded `ccallnest == 0` and counted nothing; penlight's
`tests/test-pretty.lua` (pcall inside a `for ... in` loop) ended in "C stack
overflow" under `-jon`. A second version stored the increment before the call
setup and the decrement on the return. That is exact only as long as nothing
exits between a store and the next snapshot.

## What can leave a trace

| way out | state the interpreter resumes in |
|---|---|
| guard | the last snapshot in front of the guard |
| error raised by compiled code (out of memory in an allocation, an error from a helper) | the snapshot that covers the faulting machine code |
| GC check at the head of a trace or loop | the snapshot at that head |

Snapshots without a guard behind them are merged into the next one, in the
recorder (`lj_snap_add`) and again in the loop copy (`loop_subst_snap`). Stock
relies on that being invisible, because only guards use a snapshot. An error
raised by compiled code does not go through a guard, so after a merge it
unwinds to an older state: inside a pcall that has already returned, or in
front of a pcall that is already running.

## Rules the recorder follows

1. The limit guard (`ccallnest < 200`) is emitted after the call setup. It and
   the guards of the setup (callee identity, `__call` lookup) belong to the
   state in front of the pcall, where memory still holds the old count.
2. The change of the counter is left pending in `J->ccallpend` and stored as
   the first instruction behind the next snapshot: the snapshot that has the
   pcall frame for the increment, the one without it for the decrement.
   Anything the recorder emits before that snapshot (a pending comparison
   guard, the rest of a concatenation) still belongs to the old state.
3. Both stores are typed as guards. They never exit, but a guard behind a
   snapshot keeps it from being merged, so the two boundaries stay where the
   stores are even if the protected call has no guard of its own.
4. Dead-store elimination never drops a store to this field
   (`lj_opt_dse_fstore`).
5. A trace cannot return through a pcall frame it did not enter
   (`NYI: return to lower frame`), and it cannot end with a pending change.
6. Only x64 and arm64 with on-trace error handling (`LJ_UNWIND_JIT`) record
   pcall/xpcall. Elsewhere the recorder aborts as before: the other
   interpreters do not count, and without on-trace unwinding an error would
   leave the protected call without a decrement.

| path | who decrements |
|---|---|
| the call returns inside the trace | the store behind the snapshot that drops the frame |
| guard fails inside the protected call | the interpreter, when the restored pcall frame returns or catches |
| guard fails in the call setup | nobody: the increment has not been stored |
| error raised by compiled code inside the protected call | the interpreter's catch in the restored pcall frame |
| error raised by compiled code after the call returned | nobody: the store ran, the snapshot has no pcall frame |
| side trace starts inside the protected call | the side trace, when it records the return (its parent stored the increment) |
| trace is stitched or linked to the interpreter inside the protected call | the interpreter |
| coroutine switch | separate counter per thread; `coroutine.yield` is not compiled |
| finalizer on a GC step | its own pcalls are balanced before the step returns |

## Tests

- `tests/d54/err_05_pcall_trace.lua`: the penlight shape, an error in the
  callee, a side exit, `coroutine.wrap`.
- `tests/d54/err_06_pcall_trace_paths.lua`: a callee, callable object or
  handler that changes between iterations (guards in the call setup), an
  argument type that changes, an error raised by compiled code, nested
  protected calls, pcall as `__concat`, recursion, a yield across the call, a
  finalizer that runs pcall. Each case prints the change in usable nesting
  depth.
- `tests/capi/test_capi.c` `oom_pcall`: an allocator with a byte budget; the
  out-of-memory error is raised inside a protected call with and without a
  guard, and behind one, with the JIT on and off.

## Numbers

`tests/bench/b5_pcall.lua`, x64, 2M iterations each: pcall 150 ms without
recording, 47 ms with it; xpcall 150 ms and 2.8 ms.

## spectral-norm

`tests/bench/spectral-measure.py` runs one classic benchmark interleaved
against stock 2.1. x64, median of 7: stock 15.4 ms, this tree 16.0 ms (about
4 %). The `-jdump` comparison of the first trace shows the same `tab.meta`
guard on both sides; the differences are the order of that guard against the
array access, SLOAD flags (`RI`/`TI` against `CRI`/`CI`) and about twice the
number of traces. Nothing was changed for it.
