# istailcall without a hook: a tail-call mark in the frame

Branch `istailcall`. `debug.getinfo(level, "t").istailcall` was the last
`db.lua` item named in `tests/known-bad.tsv` (line 619): PUC 5.4 reports true
for every Lua function entered by a tail call, here it was true only while a
call hook was installed.

## What PUC does

`luaD_pretailcall` sets `CIST_TAIL` in the CallInfo of a Lua callee. A C
function reached by `OP_TAILCALL` goes through `precallC` like any call and
has no flag. The flag has three consumers: `getinfo` option `t`, the hook
event `"tail call"` instead of `"call"`, and `funcnamefromcall`, which gives
no name to a function entered by a tail call (the call site in the frame
below belongs to the function it replaced). `luaL_traceback` prints
`(...tail calls...)` after such a level.

## The mechanism

`BC_CALLT`/`BC_CALLMT` to a Lua function replaces the calling frame. The new
frame's **function slot** (`base[-2]`) gets the tag `LJ_TTRACE` instead of
`LJ_TFUNC`. The two tags differ in bit 47 only, so the interpreter clears one
bit of the value it stores anyway:

    x64:    btr RB, 47                       ; before  mov [BASE-16], RB
    arm64:  and TMP1, TMP1, #FRAME_TAILCLR   ; before  str TMP1, [BASE, FRAME_FUNC]

On x64 the dispatch to the callee used to reload the function from the slot
it had just stored and strip the tag again (`mov RB, [BASE-16]`, `shl`,
`shr`). It now takes the untagged pointer that `BC_CALLT` already has in
`TMPR` for its C-function test, so neither the store nor the mark is on the
path to the next instruction (see the measurements: the first version had the
bit clear on that path and cost 2 to 7 % in the interpreter).

`frame_istail(frame)` in `lj_frame.h` tests `itype(frame-1) == LJ_TTRACE`.
Frames set up by anything else have the plain tag: calls, C functions and fast
functions (their caller frame is kept, see `tailname.md`), and a fast function
that hands over to a metamethod through `vm_call_tail` (in PUC that is a call
made by a C function, not a tail call).

### Why the function slot and not the frame link

- The frame link of a Lua frame is the return PC. Its low two bits are the
  frame type, bit 2 is a real address bit (bytecode is 4-byte aligned), and a
  mark in the high bits would have to be masked off on every return on x64.
- A frame type of its own for tail-called frames would take every return of
  such a function off the fast path (`return f(x)` wrappers are everywhere).
- A side table (the old per-thread bitmap) has to be maintained on every call,
  which is why it only existed while a call hook was set.
- The function slot costs nothing to read: every reader already masks the tag.
  The interpreter loads it with `cleartp` (x64) or `and ..., #LJ_GCVMASK`
  (arm64) wherever it reads `[BASE-16]` as a function, C code goes through
  `frame_gc`/`frame_func`/`curr_func` (`gcval` masks), and traces load it
  with an untagged `SLOAD`.
  Writing it costs the one instruction above, in `BC_CALLT` only.
- The GC needs no change: `gc_marktv` treats the slot as a GC value (the tag
  is in the GC range) and marks the object by its own `gct`. Only the
  assertion that tag and object type agree knows about the mark.
- Bytecode cannot address the slot, and `debug.getlocal` stops below it, so
  the tag does not escape into a Lua value.
- `LJ_TTRACE` is otherwise found on the stack in one place only: the trace
  that trace stitching parks in a value slot of the calling frame. That is
  never the function slot of a frame.

A vararg function copies its function slot to the vararg frame; the copy
keeps the mark (`BC_FUNCV` on x64 copied the slot already, arm64 rebuilt the
tag and now copies the slot, one load instead of two instructions). The mark
lives in the stack, so coroutines, stack growth and error unwinding need
nothing: a frame that survives keeps it.

## The JIT

- `rec_callt` flags the function's slot in the recorder's model with
  `TREF_TAIL`; snapshots carry it as `SNAP_TAIL` (bit 0x200000 of the entry,
  next to `SNAP_FRAME`/`SNAP_CONT`/`SNAP_KEYINDEX`). `rec_func_vararg` copies
  the TRef with its flag, like the VM copies the slot.
- A frame is materialised in three places, all of which write the mark for a
  `SNAP_TAIL` entry: `lj_snap_restore` (trace exit), and `asm_stack_restore`
  in the x64 and arm64 backends (the stores before a trace links to another
  trace or to the interpreter). `lj_snap_replay` hands the flag to side
  traces, `snap_dedup` strips it from a shared ref.
- Tail recursion compiled as a loop writes the function slot on every
  iteration already (the slot holds a constant, which the snapshot sees as
  modified). The mark changes the constant, not the number of stores.
- The root frame of a trace existed before the trace, and the trace does not
  know whether it is marked. Two rules keep it intact:
  the late specialization in `rec_upvalue` (`J->base[-2] = kfunc`) keeps the
  flag, and `snapshot_slots` never restores slot 0 unless it has the flag,
  i.e. unless a tail call was recorded in that frame. Without the second rule
  a trace that starts in a tail-called function and reads a constant upvalue
  wrote the plain function back at its exits and lost the mark.
- With `LUA_USE_ASSERT`, `rec_check_slots` compares the flag with the mark the
  interpreter left on the stack for every function slot of the model, so a
  recorder path that forgets or invents a mark fails at the next instruction.

## Hooks

The `"tail call"` event now comes from the same mark: `lj_dispatch_call`
tests `frame_istail(L->base-1)`. The old machinery is gone: the per-thread
bitmap (`tailbits`, `tailbitsz`, `tailhi`, `tailepoch`), `g->hookepoch`,
`g->tailofs`, and the dispatch override that sent `BC_CALLT`/`BC_CALLMT`
through `lj_dispatch_ins` while a call hook was set. A hook installed in the
middle of a chain of tail calls sees the marks of the frames that were
entered before it.

## Also changed for PUC parity

- `debug.getinfo` option `n` gives no name for a function entered by a tail
  call, and `debug.traceback` prints `(...tail calls...)` after such a level.

`db.lua` then ran past line 619 and stopped at other items, one at a time.
Fixed here, each covered by `tests/d54/debug_06_names.lua`:

- x64 only: `coroutine.resume` of a coroutine that ends in an error crashed
  while a return hook was set. The error path loaded the count into `CARG3`
  before it copied `BASE` into `CARG2`; `CARG3` is `BASE` in the SysV ABI, so
  `lj_dispatch_pret` got the pointer 1.
- `debug.getinfo(f, "u").nups` is the real count for the closures a library
  function builds per call (the `string.gmatch` iterator, the function made
  by `coroutine.wrap`); both are C closures with upvalues in PUC as well.
- `debug.traceback(co, nil, level)`: a nil message is no message. Only a
  message that is neither a string nor nil is returned untouched.
- `activelines` contains the line of the function's `end`: 5.4 ends every
  function with a return there, here a function whose last statement is a
  return has no instruction at that line.
- A metamethod frame is named without the `__` prefix (`"index"`, `"add"`),
  in `getinfo`, tracebacks and argument errors (`bad argument #1 to
  'index'`). The traceback used to strip the prefix itself, and did so for
  methods too.
- The bit operators name their metamethod frame (`band` ... `bnot`).
- The call of a generic `for` iterator is `"for iterator"`.
- A finalizer called by the collector is `metamethod '__gc'` (new
  `g->finbase`, the frame of the running `__gc` call in the VM thread).
- Tracebacks follow lauxlib: 10 levels, `...\t(skipping n levels)`, 11
  levels, decided by the distance to the last level and not by the absolute
  level.
- Code without debug info: an upvalue is `(no name)` for
  `debug.getupvalue`/`setupvalue` and `?` in an error message, `currentline`
  is -1, a runtime error has the position `?:-1:` and `error()` adds none.

## What is left in db.lua

`tests/corpus/puc54/db.lua` is now in `tests/known-different.tsv` (all modes):

1. Line 913, `repeat local a = {} until name`, waits for the finalizer of a
   table created by `setmetatable({}, {__gc = ...})` as a statement. The
   table stays in the argument slot of that finished call. PUC limits the
   stack scan of a collection started by `OP_NEWTABLE` to the register of the
   new table, so the slot is dead for it; here the stack is scanned up to the
   frame top, as in LuaJIT. The manual does not say when an object becomes
   garbage. The loop does not end, and since the JIT sinks the allocation it
   does not end in any mode. The runner bounds the file at 10 s
   (`VENDORED_DIRECTIVES` in `tests/lib/runner.py`); it reaches the loop in
   about 0.1 s.
2. With that loop bypassed (a call that overwrites the slot), one assertion
   is left, line 1002: `debug.getinfo(f).linedefined > 0` for a function
   loaded from a stripped dump. The private dump format drops `firstline`
   and `numline` when stripping; PUC keeps `linedefined`. Everything else in
   the file passes, including its last three sections.

## Tests

- `tests/d54/debug_05_istailcall.lua`: tail call, plain call, tail and plain
  recursion at depths 0, 1, 2, 100, vararg functions, `__call`, a metamethod
  behind a fast function, methods, tail calls into C functions that call
  back, the C function itself, coroutines (resumed by a tail call, tail calls
  across a yield, a suspended coroutine seen from outside), errors (traceback
  shape and text, the handler's view, frames that survive a caught error), a
  hook set and removed in the middle of a chain, hook events; then the same
  shapes in hot loops: tail recursion as a loop, inlined tail calls with a
  rare exit in the callee, a side trace that starts in a tail-called
  function, varargs/`__call`/methods, tail calls into C, return to a lower
  frame, a stack slot used by a tail-called and then by a plain frame, tail
  calls in a coroutine, collections with marked frames live.
- `tests/d54/debug_06_names.lua`: the items of the list above.

Both are red on main (7e8e4bf9) in mode A: the first differs from PUC in 43
lines, the second in 27 and ends in an error at its first traceback check.
The x64 crash was reproduced on main with the corresponding section of
`db.lua` (lines 757 to 836).

## Measurements

x64, one pinned box, main (7e8e4bf9) against this branch, both built in the
same job, arms interleaved, 7 runs each, median wall time in ms. The driver
waits for the child with a blocking `wait4`: `subprocess.run(timeout=...)`,
as used by `tests/bench/classic/run-interleaved.py`, polls with sleeps of up
to 50 ms and quantizes the result (the first run of this comparison showed
steps of exactly 50.1 ms).

Tail calls (`interp` is `-joff`):

                         main    branch   branch/main
    tailrec jit          4971.3  4968.4   0.999    self tail recursion, 300 x 1e6
    tailrec interp       2344.3  2225.4   0.949
    tailwrap jit          285.3   285.3   1.000    wrapper ending in a tail call
    tailwrap interp      1493.0  1465.4   0.982
    tailmutual jit        312.2   312.1   1.000    even/odd mutual tail recursion
    tailmutual interp    1270.9  1168.6   0.919
    tailmethod jit        769.8   828.8   1.077    vararg method wrappers, see below
    tailmethod interp    2502.5  2430.1   0.971

Classic set (pinned sizes of `tests/bench/classic`, then larger inputs for
the programs that finish in a few ms):

    nbody                   8.4     8.4   1.001
    spectral-norm          19.3    19.4   1.004
    fannkuch-redux         61.3    62.0   1.011
    binary-trees          863.3   854.7   0.990
    fasta                   9.3     9.2   0.996
    deltablue           18872.9 19370.4   1.026    spread 9.4 % in both arms
    scimark             29485.5 29556.2   1.002
    k-nucleotide           66.1    66.3   1.002
    regex-dna              62.4    62.4   1.001
    nbody 2e6             867.8   874.3   1.008
    spectral-norm 1500    748.6   748.5   1.000
    fannkuch-redux 10     674.1   682.9   1.013
    fasta 2e6            1041.7  1037.8   0.996

Compiled code: the trace of `tailrec` is the same machine code in both builds
(`-jdump` differs in one address constant). The interpreter is faster than
before because of the shorter dispatch path in `BC_CALLT`. The first version
of this branch, with `btr` in front of the reload, measured 1.019, 1.028,
1.071 and 1.007 in the four `interp` rows.

`tailmethod jit` is the one row that got slower, by one cycle per iteration,
stable to 0.1 %. Its trace is the same in both builds too (same IR, same
instructions; only hash slot numbers differ, and those change from run to run
with the string hash seed). The loop calls the C helper `lj_vm_modi` for
`i % 7` and touches no memory. That function sits at another address in the
binary because objects in front of it changed size (0x176a0 on main, 0x17490
here). With `-falign-functions=64` in both trees the row is 769.9 against
770.0. It is link layout, not the mark; any change of code size in front of
`lj_vmmath.o` can flip it.
Rows repeated with `-falign-functions=64` in both trees (same box, 7 runs):

    tailmethod jit        769.6   769.6   1.000
    tailmutual interp    1265.9  1186.2   0.937
    tailmethod interp    2491.5  2409.5   0.967
    nbody 2e6             867.5   866.6   0.999
    fannkuch-redux 10     677.5   691.6   1.021
    deltablue           18679.7 19965.0   1.069    spread 8.3 % / 7.8 %

`fannkuch-redux 10` is noise at this resolution: a later three-arm run on the
same box gave 687.7 for main and 683.4 for the branch.

deltablue was slower on the branch in all three runs (1.023 with the first
version, 1.026, 1.069) with a spread of 8 to 14 % inside each arm. Its trace
selection is not a stable property of a build (`docs/notes/deltablue.md`: hot
counters are hashed on bytecode addresses): one `-jv` sample had 188 traces
on main and 169 here, for the same bytecode. With the JIT off the two builds
are 93.66 s and 95.88 s in the median of 5 (1.024) and 93.40 s and 93.93 s in
the minimum (1.006), with spreads of 7.7 % and 3.0 %. Nothing in these numbers
separates the branch from main for deltablue; they do not prove equality
either.

## Gates

On x64 and on arm64, same counts on both:

- `tests/ci-box.sh`: all stages passed. A+B 191 PASS / 0 FAIL / 5 XFAIL, mode
  B at -O0..3 420 PASS, mode R 105 PASS, GC stress 91 PASS / 1 XFAIL, C API
  231 + 92 + 18.
- `tests/ci-local.sh --sanitizers-only`: `ci-local: OK`, harness 296 PASS /
  0 FAIL / 5 XFAIL.
- `tests/harness.sh --mode all --timeout 120 --strict` (the public CI
  command): 352 PASS / 0 FAIL / 9 XFAIL / 12 SKIP / 0 TIMEOUT. The two new
  XFAIL are `db.lua` in modes B and R, where both arms now run into the loop
  of line 913 (they used to stop at the same assertion, which counted as a
  pass).
- Not a gate, x64 only: a `-DLUA_USE_ASSERT -DLUA_USE_APICHECK` build passes
  the d54 corpus in modes A+B and mode B at -O0..3. That build has the
  recorder's check of the tail flag against the stack.

## Open

- `db.lua` cannot pass without a more precise stack scan (see above). The
  liveness analysis the JIT uses for snapshots (`snap_usedef`) would give the
  collector the dead slots of a Lua frame; that is a GC change with its own
  risks and was not attempted here.
- Stripped dumps without `linedefined`: a dump format change.
- The interpreters of the other architectures do not set the mark, and their
  backends do not restore it (`LJ_FRAME_TAILMARK` is 0 there: `istailcall` is
  always false and there is no `"tail call"` hook event). They are not ported
  to the 5.4 VM in other respects either.
- The speed of `%` in compiled loops on x64 depends on where the linker puts
  `lj_vm_modi` (7 % between two addresses on the measured CPU). Aligning that
  function would take it out of future comparisons.
- `tests/bench/classic/run-interleaved.py` and every other driver that times
  with `subprocess.run(timeout=...)` measures in steps of up to 50 ms.
- The return hook of a Lua function that ends in a tail call to a C function
  is still missing (`tailname.md`); unrelated to the mark.
