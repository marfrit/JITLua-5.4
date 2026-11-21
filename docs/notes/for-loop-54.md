# Numeric `for` with Lua 5.4 semantics (design, 2026-11-21)

Status: design, not implemented. Replaces the `tests/known-bad.tsv` row for
`tests/d54/for_01_int64_control.lua` once done.

## What differs today

`lj_meta_for` (`src/lj_meta.c`) keeps LuaJIT's dual-number rule: all three
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
3. Error texts: `'for' initial value must be a number`, `... limit ...`,
   `... step ...` (`luaG_forerror`), `'for' step is zero`.

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
   47-bit inline, or the interned box).
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
