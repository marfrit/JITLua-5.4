# Weak-table loop hang under the JIT

## Symptom

PUC's `closure.lua` never finished with the JIT on. Line 37 waits for a weak
entry to be collected:

```lua
local x = setmetatable({[1] = {}}, {__mode = 'kv'})
while x[1] do            -- repeat until GC
  local a = A..A..A..A   -- create garbage
  A = A + 1
end
```

The interpreter leaves the loop after about a thousand iterations. The compiled
loop never did. Stock LuaJIT 2.1 behaves the same way on this loop.

## Causes

1. **No collection is driven.** The string built in the body is unused, so
   dead-code elimination removed the allocation. Without an allocation the
   trace has no GC check and never calls the collector.
2. **A stale stack slot is a GC root.** The interpreter writes `x[1]` into a
   temporary slot before it tests it. A trace keeps its values in registers
   and never writes that slot, so the value the interpreter left there before
   the trace was entered stays on the stack, below the frame top, for as long
   as the trace runs. The collector marks it on every cycle. The same happens
   with the slots of a called function (`while get(x) do`) and with the result
   slots of `next`.

Each cause alone is enough to keep the entry alive.

## Fix

A trace that reads from a table which is weak at record time is marked
(`GCtrace.weak`). A side trace inherits the mark from its parent. A marked
trace differs in three ways:

- **Allocations are kept** by both DCE passes (`lj_opt_dce.c`, `lj_asm.c`),
  so the heap grows and the GC check has something to trigger on.
- **The loop always has a GC check**, even when all its allocations sit in
  side traces.
- **The GC step at the loop head clears the dead stack slots.** A GC check
  that runs at the start bytecode of the root trace passes the trace number
  and a flag to `lj_gc_step_jit`. That is the check at the `LOOP` instruction
  of an optimized loop, at the head of a root trace, and at the head of a
  side trace that forms a loop of its own. Before the step, the helper sets
  every slot above the loop's own variables up to the frame top to nil. The
  bound comes from the loop bytecode the root trace started at: its `A`
  operand is the first free slot for `LOOP` and `ITERN`, and `FORL` and
  `ITERL` add their control and result slots. All slots above it are dead at
  the loop head. Other side traces, traces that start at a function or after
  a call, and explicit `GCSTEP` checks clear nothing: there is no such bound
  for them.

The arguments travel in one 64-bit immediate (trace number, flag, step
count), loaded into the register the step count used before. The check is
emitted backwards and its call is skipped while the heap is below the
threshold, so nothing in that region may touch the register allocator; the
clearing therefore happens in C, not in machine code.

A trace recorded for a strong table must not run for a weak one, and the
reverse. Every table a trace reads from gets a guard on its metatable and, if
it has one, on the value of the metatable's `__mode` field. The field is
looked up as a constant key of a constant table, so the check is invariant and
shared by all tables with that metatable. The negative metamethod cache
(`nomm`) is not usable for this guard: every string-keyed store to the
metatable clears it, which would throw a class's methods out of compiled code
whenever a static field of the class is written.

## Cost

Measured against the tree before the fix, both in one job, median of 7 runs.
The classic benchmarks (nbody, spectral-norm, fannkuch, binary-trees, fasta,
deltablue, scimark, k-nucleotide, regex-dna) do not move: within 3 % on x64
and arm64.

- The metatable guard is one compare per table operand with a metatable. A
  loop that does nothing but call a method on changing objects is 8-11 %
  slower.
- A weak loop that allocates nothing still gets the GC check at its head. A
  loop that only reads a weak-valued memo table is about 30 % slower on x64,
  half of it from the check and half from the guard.

## Limits

- A loop that allocates nothing never runs the collector, with or without the
  JIT, and in PUC 5.4 as well. `tests/d54/weak_noalloc_boundary.lua` records
  this.
- The mark belongs to a trace, not to a loop. If the root trace of a loop was
  recorded with a strong table and a weak one arrives later, the guard exits
  to a side trace. A side trace that covers the whole loop is marked and
  clears. A side trace that only covers a part and links back to the unmarked
  root relies on the root's allocations, and those may have been eliminated.
- The 32-bit backends keep the two-argument call and clear nothing. They are
  not built or tested in this fork.

## Tests

`tests/d54/weak_*.lua`. Each loop is bounded, so a regression fails instead of
hanging.

| file | covers |
|---|---|
| `weak_closure_shapes.lua` | the `closure.lua` loop and the form with a local bound |
| `weak_callee_next.lua` | read in a called function, `next`, allocation in a side trace |
| `weak_str2weak.lua`, `weak_setmt_after.lua`, `weak_mode_rawset.lua`, `weak_mode_tsets.lua` | a table that becomes weak after the loop was compiled |
| `weak_mt_store_traces.lua` | stores into a metatable do not fail the guard |
| `weak_gcstep_regs.lua` | many live values across the GC check of a weak loop |
| `weak_noalloc_boundary.lua` | the no-allocation limit |
