# Numeric `for` with Lua 5.4 semantics (design, 2026-11-21)

Status: implemented 2026-11-21. Replaces the `tests/known-bad.tsv` row for
`tests/d54/for_01_int64_control.lua`; the rules are checked by
`tests/d54/for_02_54_rules.lua`.

## What differed before the change

`lj_meta_for` (`src/lj_meta.c`) kept LuaJIT's dual-number rule: all three
control values int32 -> integer loop, otherwise all three become floats.
PUC 5.4.9 (`lvm.c` `forprep`/`forlimit`/`OP_FORLOOP`) decides on the
*initial value and the step only*. Measured on x86_64, `-joff` and `-jon`
alike:

| loop | PUC 5.4.9 | here |
|---|---|---|
| `for i = 1, math.huge` | `i` integer | float (`print(i)` -> `1.0`) |
| `for i = 1, 10.5` | integer, 10 iterations | float |
| `for i = 1, 1 << 40` | integer | float |
| `for i = 1 << 40, (1 << 40) + 2` | integers | floats |
| `for i = math.maxinteger - 2, math.maxinteger` | 3 iterations | does not end |
| `for i = math.mininteger + 2, math.mininteger, -1` | 3 iterations | does not end |
| `for i = 1, 2, 0` and `for i = 1.0, 2, 0.0` | error `'for' step is zero` | endless loop |
| `for i = 1, "2"` | integer loop (limit string converted) | same |

The first two are common idioms, so this is not an edge case.

## PUC's rule (the specification)

1. Integer loop iff the initial value and the step are both integers (no
   string coercion for these two: a string makes it a float loop).
   - step 0 -> `'for' step is zero`.
   - limit: `luaV_tointeger(lim, floor if step > 0 else ceil)`; a string is
     converted; a float outside the integer range clips to maxinteger /
     mininteger, or skips the loop when it lies on the wrong side; anything
     else -> `'for' limit must be a number`.
   - skip if `init > limit` (step > 0) / `init < limit` (step < 0).
   - iteration count precomputed as unsigned: `(limit - init) / step`, or
     `(init - limit) / (-(step + 1) + 1)` for step < 0. The loop runs
     count + 1 times and the index wraps like `intop(+)`: no overflow test,
     no endless loop at the integer limits.
2. Otherwise a float loop: all three converted with `tonumber` (strings
   allowed), error order limit, step, initial value; step 0.0 -> the same
   error; skip test; then `idx += step` while `idx <= limit` (or `>=`).
3. Error texts as PUC's `luaG_forerror` and `luaG_runerror`: `bad 'for'
   <what> (number expected, got <type>)` for initial value, limit and step,
   and `'for' step is zero`.

## Design

Three loop kinds after FORI:

- **small integer loop**: init, step and the clipped limit all fit int32.
  Slots hold int32 as today; the existing int32 fast paths of FORI/FORL/
  IFORL/JFORI are already exact for it (an int32 overflow of idx + step
  means idx > limit, so leaving the loop is PUC's result). No change in the
  per-iteration code.
- **float loop**: as today.
- **wide integer loop**: an integer loop where any of init, step, clipped
  limit is outside int32 (this includes `1, math.huge`). New.

Changes:

1. `lj_meta_for` implements `forprep` exactly (the three kinds, the clip and
   skip rules, step 0, errors in PUC's order). For a wide loop it stores
   PUC's state (current index, remaining count, step) in a private mutable
   object in `FOR_IDX` (one allocation per loop start, none per iteration)
   and the control variable in `FOR_EXT` in canonical form (int32, widened
   47-bit inline, or the interned box). The object also carries the loop body
   address: a patched JFORL has no jump target of its own (its field holds the
   trace number), and a wide loop must not enter a trace recorded for another
   loop kind.
2. FORI/JFORI (interpreter, both backends): step 0 -> `->vmeta_for`, in the
   int32 path and in the FP path. This runs once per loop start.
3. FORL/IFORL (interpreter): the FP path (label 9) must recognise the wide
   state instead of reading it as a double: one type check of `FOR_IDX` in
   the FP path only, branching to a new `->vmeta_forl` stub that calls a C
   helper (count, add with wrap, FOR_EXT, continue/leave). The int32 path is
   untouched. `->vmeta_for` must also handle a FORI that ends up wide: the
   helper decides enter/skip and the stub branches, instead of re-executing
   the FORI (which would loop back into `->vmeta_for`).
4. JIT (`lj_record.c`, FORI/FORL recording): small integer and float loops
   unchanged. A wide loop is not recorded (NYI abort, the interpreter runs
   it) in this step. The recorder's own call of `lj_meta_for` and the
   int64-to-float conversion added for ADR-001b (the block at the
   `tvisi64any` loads) are replaced by the new rule. Step 0 never reaches a
   trace: FORI/JFORI catch it before the loop is entered.
5. Backends: x86_64 and arm64 (the two built and tested). Other `vm_*.dasc`
   files keep compiling; note in DIFFERENCES that they are not ported.

Performance constraints, measured before/after in one interleaved box job
(median of 7): an int32 `for` loop and a float `for` loop must not get
slower beyond noise (the FP path gains one type check per iteration;
measure it). A wide loop costs one C call per iteration in the interpreter;
record that number. A later step can keep `for i = 1, math.huge` on the
int32 path until the index leaves int32.

## Tests (before the code, MISSION section 7.2)

`tests/d54/for_02_54_rules.lua`, modes A and B (B at opt levels), every row
of the table above plus: descending wide loops; step = maxinteger,
mininteger; limit = `math.huge`, `-math.huge`, NaN (`0/0`: skip), a float
just outside the integer range; string init (float loop), string limit with
integer init; `math.type` of the control variable on the first and last
iteration; the iteration count; the three error messages and their order;
a hot loop (> 200 iterations) of each kind under `-jon`, so trace exits and
the NYI abort are exercised; a wide loop with a `break` and with a `goto`
out; a coroutine yield inside a wide loop. Endless-loop risks get an
iteration guard in the test, never a timeout.

## Revision: plain slots instead of a state object (2026-11-21)

The first implementation kept a wide loop's state (index, count, step, body
address) in a private userdata in `FOR_IDX`. A pre-push review found that
the debug library could reach it: `debug.setlocal` on the step slot of a
float loop sent FORL to `lj_meta_forl`, which read the float in `FOR_IDX` as
the state object (SIGSEGV and a write through a forged pointer, both
architectures, `-joff` and `-jon`); a state copied into another loop jumped
to the body address of a different function; `debug.getlocal` showed the
object as a userdata; and every loop start allocated it.

Now the slots hold plain numbers, as PUC's do:

| slot | small integer | wide integer | float |
|---|---|---|---|
| `FOR_IDX` | int32 index | index, canonical (an int32 index as a float, see below) | float index |
| `FOR_STOP` | int32 limit | converted limit, canonical | float limit |
| `FOR_STEP` | int32 step | step, canonical | float step |

The int32 FORL path takes an int32 `FOR_IDX` as its only witness and reads
the other two slots by their low words, so a wide loop whose index fits
int32 while the limit or step does not stores the index as a float (exact).
FORL reaches its FP path for every wide loop (`FOR_IDX` is no int32), finds
an integer step there and calls `lj_meta_forl`, which reads the three slots
as they are, decides with an overflow-free limit test (the same iterations
as PUC's precomputed count), writes the canonical control variable and the
index and returns the body PC, taken from the FORL instruction itself (for a
JFORL from the trace's start instruction). When index, limit and step all fit
int32 again it stores them in the int32 form and the int32 path takes over,
which is exact for such values. Values written through the debug library are
handled by the same code; the rules are in `docs/DIFFERENCES.md`.

The recorder no longer calls `lj_meta_for` before the FORI executes (that
call converted the slots in place and made the trace load the converted
types). `lj_meta_forkind` classifies without side effects, and the trace
converts like `forprep`: floor/ceil for a float limit of an integer loop
under a range guard, `tonumber` (including `CONV num.i64`) for a float loop.
A zero-trip loop is recorded as a guarded skip, a float FORI enters on an
unordered comparison like the interpreter. The FORL/loop-start recorder
aborts unless the slots are all int32 or all floats.

### Measurement (2026-11-21)

One interleaved job per architecture, the tree before this revision against
it, median of 7, seconds of `os.clock` per shape (base/head > 1: faster):

| shape | mode | x86_64 base | head | b/h | arm64 base | head | b/h |
|---|---|---:|---:|---:|---:|---:|---:|
| int32 loop, 1e8 | -joff | 0.827 | 0.827 | 1.00 | 0.426 | 0.412 | 1.04 |
| int32 loop, 1e8 | -jon | 0.068 | 0.069 | 0.99 | 0.026 | 0.026 | 1.00 |
| float loop, 1e8 | -joff | 3.243 | 3.070 | 1.06 | 0.552 | 0.551 | 1.00 |
| float loop, 1e8 | -jon | 0.284 | 0.284 | 1.00 | 0.060 | 0.060 | 1.00 |
| `1, #t/2`, odd `#t` | -jon | 0.394 | 0.0156 | 25.2 | 0.235 | 0.0058 | 40.6 |
| zero-trip inner loop | -jon | 0.0604 | 0.0023 | 26.3 | 0.0245 | 0.0011 | 22.3 |
| `1, math.huge` + break | -jon | 0.527 | 0.586 | 0.90 | 0.102 | 0.105 | 0.98 |
| `1, 1e10` + break | -jon | 0.526 | 0.585 | 0.90 | 0.100 | 0.104 | 0.96 |
| wide `1<<40`, 3e6 | -jon | 0.0746 | 0.0906 | 0.82 | 0.0149 | 0.0161 | 0.93 |

Under `-joff` the last three shapes measure the same as under `-jon` (they
are never recorded, in either tree), and the half-limit and zero-trip shapes
are unchanged (x86_64 0.413/0.413 and 0.060/0.060 s). The wide C path
costs about 6 ns more per iteration on x86_64 (a GC check and the slot
reads that replace the state object's fields); the int32 and float fast
paths are unchanged.

## Next step: huge limits on the int32 path (design, not implemented)

`for i = 1, math.huge` and `for i = 1, 1e10` are wide loops because the
clipped limit lies outside int32; the interpreter calls `lj_meta_forl` on
every iteration and the loop is never compiled. Most such loops end with a
`break` long before the index leaves int32. Plan:

1. FORI (C, `lj_meta_for`): int32 start and step, limit beyond int32 on the
   far side of the start (step > 0: above `INT32_MAX`; step < 0: below
   `INT32_MIN`). Store the clip value `C = INT32_MAX - step` (or
   `INT32_MIN - step`) in `FOR_STOP` as int32, push `{slot offset, real
   limit}` on a per-thread list (like the pending `<close>` list, after
   dropping every entry at or above this slot: those loops are gone), and
   enter the body directly (status WIDE: re-executing the FORI would come
   back here).
2. FORI/JFORI fast paths: a limit equal to `C` for the current step goes to
   `vmeta_for` (once per loop start), which drops the stale entries of the
   slot and enters the body, so only a loop that went through step 1 can
   leave the int32 path with that limit.
3. FORL/IFORL/JFORL int32 paths: unchanged per iteration. On the exit edge
   (index passed the limit) compare the limit with `C`; equal -> a stub
   calls C, which pops the slot's entry if there is one and continues the
   loop as a wide loop from the new index (slots rewritten in the wide form,
   jump to the body), otherwise it is a genuine exit. With `C + step <=
   INT32_MAX` the int32 add never overflows, and `rec_for_check`'s overflow
   guard passes, so the loop can be compiled.
4. Recorder: a loop trace whose limit is `C` gets its loop-exit snapshot at
   the FORL itself with the index before the increment (not after the loop),
   so a trace exit re-executes the FORL in the interpreter, which takes the
   exit edge of step 3. Re-executing the FORL is equivalent for every
   activation, clipped or not. A FORI recorded inside another trace with a
   clipped limit stays NYI (it would need a call that pushes the entry).
5. Semantics unchanged: integer control variable, PUC's iteration count;
   the only new state is the list entry, which never holds a GC object.

Risks: the exit edge exists in three opcodes and two backends; the snapshot
change touches the loop-exit path of every compiled numeric loop with that
limit; a forged `C` limit through the debug library can pick up a stale
entry (no memory hazard, an arbitrary count as for the other forged slots).
