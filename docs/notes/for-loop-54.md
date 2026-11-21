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

## Huge limits on the int32 path (step 4c, 2026-11-21)

`for i = 1, math.huge`, `for i = 1, 1e10` and `for i = 1, math.maxinteger`
are wide loops because the converted limit lies outside int32: before this
step the interpreter called `lj_meta_forl` on every iteration and the loop
was never compiled (x86_64 `-jon` 0.586 s against 0.011 s for the float loop
the 2.1 coercion made of it). Most such loops end with a `break` long before
the index leaves int32. They now run on the int32 path while the index fits,
compiled or not, and continue as wide loops from there.

### Clipped loops

`lj_meta_for` (forprep): an integer loop whose initial value and step fit
int32, whose converted limit does not, and which is not skipped (so the
limit lies beyond `INT32_MAX` for a positive step, below `INT32_MIN` for a
negative one) and whose initial value is not past the clip value is a
*clipped* loop:

- `FOR_STOP` gets the clip value `C = INT32_MAX - step` (`INT32_MIN - step`
  for a negative step) as int32; `FOR_IDX`, `FOR_STEP` and `FOR_EXT` get the
  int32 index, step and control variable, the small-loop form.
- The real limit goes into a per-thread list (`lua_State.forclip`, entries
  `{stack offset of FOR_IDX, int64 limit}`, ascending by offset, no GC
  objects, offsets survive stack reallocation, freed with the thread). The
  push drops every entry at or above the slot first.
- FORI enters the body from C (status `LJ_FOR_WIDE`): re-executing it would
  come back to C.

While the index is at most `C` the int32 add of the next index cannot
overflow (`C + step` is the int32 bound), and the int32 FORL paths and a
compiled loop run it unchanged. A step whose start is already past `C`
(`for i = 2147483000, math.huge, 1000`) stays a wide loop from the start.

### The exit edge

FORL/IFORL/JFORL keep their per-iteration code. On the edge where the int32
index passed `FOR_STOP` (not the int32-overflow edge, which a clipped loop
cannot take), and only when `FOR_STOP + FOR_STEP` is the int32 bound of the
step's sign (`FOR_STOP == C(step)`, three instructions on the exit edge),
they call `lj_meta_forclip` through `->vmeta_forclip`. It looks up the slot:
an entry means the loop is clipped; it is popped together with the dead
entries above it, the index that passed `C` (it fits int32, the real limit
lies beyond it) becomes the next index of a wide loop: the slots get the
wide form (index as a float, the real limit canonical, see the revision
above) and the body PC is returned. No entry means a real limit `C`: the
loop is left. From there the loop is an ordinary wide loop (`lj_meta_forl`
per iteration).

### Why the list answers for the running loop

The list is consulted only on the exit edge with `FOR_STOP == C(step)`, for
the exact slot. The entry for slot `s` is right iff every start of a loop at
`s` with limit `C(step)` either pushes (clipped) or drops (real limit `C`)
that entry:

- interpreter FORI/JFORI: the int32 fast path tests `FOR_STOP + FOR_STEP`
  against the bound once per loop start (three instructions) and goes to
  `->vmeta_for`; `lj_meta_for` drops the entries at and above `s` for a real
  limit `C` and enters the body, it pushes for a clipped one;
- a FORI recorded in a trace: `rec_for_check` turns the existing overflow
  guard `stop <= INT32_MAX - step` into `stop < INT32_MAX - step` (an `NE`
  on the `ADDOV` sum for a variable step; for a constant stop the range
  check of the step is tightened the same way), so the trace exits to the
  FORI for that limit; a FORI that starts a clipped loop pushes the entry
  through a helper call (below, "A recorded FORI of a clipped loop"), and a
  FORI that meets the value `C` as a real limit while recording aborts;
- `debug.setlocal` on one of the three slots drops the entry for `s` (after
  turning a clipped loop into its wide form, see below);
- nothing else writes those slots while the loop runs.

Entries above `s` belong to loops that are gone when a loop at `s` starts or
ends (an active loop's inner loops and the frames it calls sit at higher
slots, coroutines have their own list), so dropping them is safe; an entry
left by a `break`, `goto`, `return` or error stays until a loop at or below
its slot starts, and is never consulted before, because the loop that owns
the slot then started without `C` or dropped it. The list is bounded by the
stack size (offsets strictly ascending).

### Compiled loops

The recorder sees a clipped loop as a small integer loop (three int32
slots), so `rec_for_isrecordable` accepts it, and the loop-start check
`stop <= INT32_MAX - step` passes for `C`. The FORL side:

- Every guard of an integer FORL (the loop-exit guard of a loop trace, the
  guards of a FORL recorded inside a trace) exits to the FORL itself instead
  of past the loop or into the body, with the index *before* the increment.
  The interpreter re-executes the FORL (one more add and compare) and
  continues, leaves, or takes the clip edge above. This holds for every
  activation, clipped or not, so it is not conditional on the limit.
- The snapshot holds the incremented index, as before, with a new entry flag
  `SNAP_FORDEC`: `lj_snap_restore` writes it back minus the step slot, and
  `lj_snap_replay` starts a side trace with `index - step` (it folds away
  against the add). The step slot is put into the snapshot for that when the
  trace has no entry for it; a step the trace only loaded from its own slot
  is left out by `snapshot_slots` like any unchanged slot (the loop header
  behind a stitched C call, `for j = 1, n, utf8.len(s)`: the trace starts
  right before the FORI, which loads all three slots), and `lj_snap_replay`
  then loads it from the stack, where the restore reads it as well. The
  first version took the missing slot for reference 0 and the side trace
  crashed (`tests/d54/for_09_stitched_header.lua`). So the
  index before the increment is never live in the loop and needs no
  register: the loop code is the same instruction for instruction (checked
  with `-jdump` on x86_64). A first version that kept the old index in the
  snapshot cost one `mov` per iteration (x86_64 `-jon`, a nested loop of 100
  iterations: 0.148 s -> 0.165 s); one that compared the old index against
  `stop - step` before the add lost the inverted loop branch (0.171 s).
- A FORL recorded leaving the loop (an unrolled inner loop, a side trace
  starting at that exit) also guards `stop != C(step)`; a FORL that leaves at
  `C` while recording aborts, and so does a loop trace whose hot FORL is
  about to take the clip edge (`LLEAVE`: the loop would come back as a wide
  loop, the body was entered from `lj_meta_forclip`).

### A recorded FORI of a clipped loop

A trace that comes around an enclosing loop meets the FORI of an inner
`for j = 1, math.huge do ... break end`. Until the review of 2026-11-21 that
FORI ended the trace (`NYI: bytecode FORI`), so the inner loop had its own
trace but everything around it fell back to the interpreter on each pass.
Now `lj_meta_forkind` reports such a start as `LJ_FOR_CLIP` and `rec_for`
records it:

- start and step are guarded to be int32 (`fori_conv`), the direction of a
  variable step is guarded, and the limit stays what it is, a float or an
  `IRT_I64` value;
- a call of `lj_meta_forclipn` (float limit) or `lj_meta_forclipi` (int64
  limit) with the base slot of the loop does what `lj_meta_for` does for a
  clipped loop: it converts the limit like `forlimit`, checks that the loop
  starts clipped (limit beyond int32 on the side the step runs to, start not
  past the clip value) and pushes the entry, keyed by the stack offset taken
  from the base the trace runs on (`jit_base`). It returns 0 without any
  effect for every other loop (a small one, a skipped one, NaN, a wide one),
  and the guard on the result exits to the interpreter's FORI, which starts
  that loop itself. The call may raise (out of memory for the list) and is
  marked so;
- the trace holds `C(step)` as the limit (a constant, or `bound - step` for
  a variable step), so every exit inside the loop writes the clipped form
  that the list entry belongs to, and the FORL of the loop behaves as
  described above.

The argument for the list holds unchanged: this start pushes like
`lj_meta_for` (dropping the entries at and above the slot first), and a loop
that is left by a `break` on the trace leaves the same stale entry the
interpreter leaves. Not recorded, as before: a limit that is a numeric
string, and a start beyond the clip value (a wide loop from its first
iteration). `tests/d54/for_10_clip_fori.lua` checks that the trace around
the loop links to compiled code instead of falling back, and the iterations
of the same FORI meeting small, clipped, skipped, NaN and clip-valued limits,
a start that crosses the int32 bound, stale entries, nested clipped loops,
errors and coroutines.

Measured with one interleaved job per architecture, the tree before against
after, median of 7, seconds: 3e6 passes of an inner `for j = 1, math.huge`
that breaks after 2 to 6 iterations, x86_64 `-jon` 0.5581 -> 0.1349, arm64
0.1046 -> 0.0227 (the same loops with the limit 1000000: 0.0640 and 0.0124,
the difference is the call per loop start); 1e6 passes of one that breaks
after 100 iterations, x86_64 0.2332 -> 0.1463, arm64 0.0523 -> 0.0312.
Unchanged within noise in the same job: a single `1, math.huge` loop of 1e7
(x86_64 0.0094 / 0.0093, arm64 0.0039 / 0.0040), an int32 loop of 1e8
(x86_64 0.0709 / 0.0707, arm64 0.0258 / 0.0258), a nested 1e6 x 100 int32
loop (x86_64 0.0849 / 0.0848, arm64 0.0279 / 0.0279), and all shapes under
`-joff`. The arm64 host served other work during the run.

`find_kinit` no longer turns a widened 47-bit constant into an int32 constant
(it took the low word): such a limit is the clipped one, and the trace must
read `C` from the slot.

### The debug view

`debug.getlocal` of the three slots of a clipped loop shows the wide form,
exactly what the slots held before this step (the index as a float, the real
limit, the step), so the `FORK` row in `docs/DIFFERENCES.md` and
`tests/d54/for_03_wide_state.lua` are unchanged. `debug.setlocal` on one of
them first turns a clipped loop into that wide form (slots rewritten, entry
dropped), then writes: the loop then behaves as the wide loop the debug view
showed, as before this step.

### Equivalence

Iterations: the int32 phase produces `init, init + step, ...` while the
index is at most `C`; the first index past `C` is at most the int32 bound
and does not pass the real limit, so the wide phase continues with it;
from there `lj_meta_forl` gives PUC's iterations as before. The union is
PUC's sequence with PUC's count, including the int64 end. The control
variable is an integer throughout. No new endless loop: the int32 phase
ends at `C`, the wide phase is bounded as before. `break`/`goto` out of the
loop leave a stale entry (see above), a coroutine yielding in the loop keeps
its slots and its thread's list, side traces and hot exits resume at the
FORL. Forged slots: a forged `FOR_STOP` equal to `C` with a stale entry
cannot occur (`debug.setlocal` drops it); the remaining forged shapes behave
as listed in `docs/DIFFERENCES.md`.

### Rejected alternatives

- A marker in the type tag of `FOR_STOP` (the int32 FORL path reads only its
  low word): it would need no list, but the recorder type-checks the slot
  and the debug view would show the marker.
- Leaving the loop-exit snapshot after the loop and continuing a clipped loop
  from the trace-exit handler: a side trace from that exit would start after
  the loop and skip the decision; the side-trace setup would need the same
  check. Resuming at the FORL keeps the decision in one place.

### Measurement (step 4c)

One interleaved job per architecture, `eda0612a` against this step, median
of 7, seconds of `os.clock` per shape (base/head > 1: faster). Loops of 1e7
iterations ending with a `break` (`s = s ~ i`), int32 and float loops of
1e8, a nested loop of 1e6 x 100.

| shape | mode | x86_64 base | head | b/h | arm64 base | head | b/h |
|---|---|---:|---:|---:|---:|---:|---:|
| `1, math.huge` + break | -joff | 0.3106 | 0.1886 | 1.65 | 0.1137 | 0.1036 | 1.10 |
| `1, math.huge` + break | -jon | 0.3108 | 0.0060 | 51.8 | 0.1138 | 0.0026 | 43.8 |
| `1, 1e10` + break | -jon | 0.3091 | 0.0061 | 50.7 | 0.1148 | 0.0026 | 44.2 |
| `1, math.maxinteger` + break | -jon | 0.3107 | 0.0060 | 51.8 | 0.1281 | 0.0026 | 49.3 |
| int32 loop, limit in a variable | -joff | 0.8264 | 0.8293 | 1.00 | 0.3927 | 0.4079 | 0.96 |
| int32 loop, limit in a variable | -jon | 0.0740 | 0.0717 | 1.03 | bimodal | | |
| int32 loop, constant limit | -jon | 0.0718 | 0.0693 | 1.04 | bimodal | | |
| float loop | -joff | 3.0696 | 3.0852 | 0.99 | 0.5615 | 0.5650 | 0.99 |
| float loop | -jon | 0.2838 | 0.2834 | 1.00 | 0.0739 | 0.0762 | 0.97 |
| nested 1e6 x 100 | -jon | 0.1478 | 0.1600 | 0.92 | 0.0521 | 0.0474 | 1.10 |

The arm64 int32 loops under `-jon` are bimodal in both trees (raw values
0.0257 or 0.035..0.038 s, base and head alike; the box serves other work);
the fastest run is 0.0257 s in both. The `-jdump` code of the int32 loop is
the same instruction for instruction on x86_64. The nested shape on x86_64
costs 2 to 8 % (inner trip counts 10, 100, 1000: +3 %, +5 %, +2 %): the side
trace at the inner loop's exit now starts at the FORL and repeats its compare
plus the guard against the clip value; the loop code itself is unchanged.
Under `-joff` the `math.huge` shapes gain from the int32 interpreter path
while the index fits.
