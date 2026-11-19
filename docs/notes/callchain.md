# The __call chain (calls.lua lines 171/193)

Branch `callchain`, on top of main `7e8e4bf9` (the tail-call-into-C recorder
rework). Known-bad is empty; the calls.lua mode-A row is now a known
difference for the private dump format.

## PUC semantics

PUC 5.4 `luaD_precall` and `luaD_pretailcall` do
`func = tryfuncTM(L, func); goto retry`. A callable table whose `__call` is
itself a callable table therefore chains: each retry prepends the current
object as an argument, replaces the func slot with its `__call` value, and
retries. The final arguments are the chain objects innermost first
(`u1,u2,...,uN`, then the real arguments), which is what calls.lua asserts
with `Res[i][1] == i`.

There is no explicit `__call` chain cap in PUC. The bound is the Lua stack
limit (`LUAI_MAXSTACK`, 1,000,000 slots), and the error is the ordinary
"stack overflow". LuaJIT's limit is 65500 slots (`src/luaconf.h`), so the
depth at which a chain overflows is implementation-defined. PUC also shifts
all pending slots on every retry, so its chain setup is quadratic; a test
that reaches PUC's own limit is not practical.

## Design

`lj_meta_call` (src/lj_meta.c) walks the chain twice:

1. Count pass: follow `__call` from the called object without touching the
   stack. Per level it makes sure there is room for the n slots counted so
   far above the call's arguments and grows the stack if not, so a cyclic
   chain terminates in a catchable "stack overflow" instead of looping. A level without `__call`
   copies that object into the func slot and raises the existing
   `attempt to call a X value`; keeping it in the func slot preserves the
   caller-side variable naming in the error.
2. Prepend pass: after the stack may have moved, rebase func/top by saved
   stack offsets, shift the arguments up once by n (linear, not PUC's
   per-level shift), write the chain objects innermost-first at
   `func+1+LJ_FR2 ...`, and put the final function in the func slot.

The stack can move, so `lj_meta_call` returns the (possibly moved) func slot.
The number of prepended objects is passed in `lua_State.metanargs`, appended
after `extraspace` so no existing field offset moves (the C API extraspace
tests still pass). The VM adds it to its own nargs bookkeeping; x64 saves
`nargs+1` in TMP1 across the C call, arm64 adds to its callee-saved RC.

The VM rebases from the returned func slot:

- x64 `vmeta_call`: `RA = func+16`, `BASE = L->base`. The CALLT hint is
  `KBASE == BASE` on entry. The old base is kept in `RB` (callee-saved)
  across the call and compared with the untouched `KBASE` afterwards; only
  when the hint was set does `KBASE` become the new base. For every other
  call `KBASE` must come back exactly as it went in: it is the constants
  base of the calling Lua function, and a fast function at the end of the
  chain returns to that function without reloading it. The first two
  versions got this wrong. One read `BASE` after `lea CARG3` had clobbered it
  (on POSIX `CARG3` is `rdx` = `BASE`), so tail calls through a chain ran the
  wrong bytecode. The next kept the hint as `KBASE-BASE` and added the new
  base back, which relocated the constants base together with the stack
  whenever the stack moved: the caller then loaded its constants from
  somewhere else in the heap (`tests/d54/call_05_chain_stack_move.lua`,
  SIGSEGV or wrong strings and numbers on x86_64).
- arm64 `vmeta_call`/`vmeta_callt`: `BASE`/`RA = func+16`, BASE reloaded from
  `L->base`. `vmeta_callt` keeps the CALLT pc (callee-saved x21) across the
  call; the merged `BC_CALLT2_Z` loads the caller frame pc only on the Lua
  path.
- Neither call site rewrites `L->top`: the `top` argument is the call's
  argument top, while `L->top` is a different, frame-relative value (at the
  call it can be below the func slot). The first implementation set
  `L->top = top+n`, which is wrong for this contract; the explicit
  `metanargs` field replaced it.

The stack reservation is measured from the call's argument top, not from
`L->top`: `L->top` is where the last C call left it, which can be far below
this call or above it. Asking `lj_state_growstack` for `top-L->top + n` slots
made the request as large as that distance, so recursion through a callable
object could end in "stack overflow" well before the limit, depending on
where the frames happened to sit (`tests/d54/call_06_chain_depth_align.lua`:
14584 against 16371 levels). When the n slots cannot be had, no target frame
exists yet, so a fast pcall/xpcall does not recognize the protected call and
the overflow used to escape. `lj_meta_call` now installs the same dummy frame that
`lj_err_optype_call` uses for a non-callable target when the current C-frame
pc is not a Lua frame, then forces the overflow through
`lj_state_growstack`; the error unwinds into pcall/xpcall and the handler
runs, on both arches. The ordinary Lua-frame recursion path is unchanged.

Recorder: `rec_call_setup` loops the chain in its slot model exactly like the
VM (depth 1 unchanged), and stops with `LJ_TRERR_STACKOV` once
`baseslot+func+nargs+2*LJ_FR2` reaches `LJ_MAX_JSLOTS`. `rec_callt_keepframe`
(main's rework) follows the chain to its final callee before choosing the
kept-frame `LJ_CONT_TAILRET` layout; `lj_record_tailcall` is the Lua-only path.
A depth-100 chain in a hot loop therefore aborts the trace cleanly and falls
back to the interpreter, with identical results.

## Tests

- `tests/d54/call_01_chain.lua` (A+B): depth 1/2/100/10000, argument order,
  tail in a new coroutine and direct, `pcall(obj, ...)` and
  `pcall(function() return obj(...) end)`, a chain ending in `table.pack`,
  and a chain ending without a callable object (type in the error).
- `tests/d54/call_02_chain_limit.lua` (B only): a 70000-object chain built
  outside `pcall`; the call inside `pcall(function() return u() end)` returns
  false with a "stack overflow" message, never crashes, and -joff/-jon agree.
- `tests/d54/call_03_chain_trace.lua` (B only): depth-1/depth-2 chains in hot
  loops (plain and tail), depth-100 chain exceeds the recorder budget.
- `tests/d54/call_04_chain_pcall_catch.lua` (B only): pcall and xpcall are
  called directly on a 70000-object chain and must return false with the
  overflow message, then the script continues. coroutine.wrap and the xpcall
  handler reject the same table as a non-function before resolution, like
  PUC, in both arms.
- `tests/d54/call_05_chain_stack_move.lua` (A+B+R): chains of 1 to 3000
  objects that end in a fast function, called first thing in a new coroutine
  (the setup has to grow and move the stack), plain, in tail position and
  under pcall; the caller uses its constants right after the call. Plus one
  level of `__call` at every stack alignment of a 3000-deep recursion.
- `tests/d54/call_06_chain_depth_align.lua` (B+R): recursion through a
  callable object reaches the same depth at every alignment.

Red evidence on the unchanged tree: calls.lua aborts at line 187 under
`-joff` and `-jon` with `attempt to call a table value`; call_01 fails mode A
at the depth-2 call; call_02 fails both arms because the chain stops at the
first non-function level; call_04 fails both arms with an uncaught
`lua: stack overflow` from the first direct pcall.

## Micro-benchmark (one pinned x64 box, base main 7e8e4bf9 vs head, interleaved)

20,000,000 calls of a depth-1 `__call` object in a hot loop, 7 alternating
runs each, medians (`-jon`):

    plain call   base 0.0280 s   head 0.0280 s   +0.0 %
    tail call    base 0.0300 s   head 0.0290 s   -3.3 %

Depth 1 is the unchanged single-level path.

## Gates (merged tree, main 7e8e4bf9)

- `tests/ci-box.sh`: all stages passed on x86_64 and aarch64.
- `tests/ci-local.sh --sanitizers-only`: `ci-local: OK` on both arches;
  d54 all modes: 296 PASS, 0 FAIL, 5 XFAIL.
- `tests/harness.sh --strict --mode all --timeout 120`: 354 PASS, 0 FAIL,
  7 XFAIL, 12 SKIP.
- d54: A+B 192 PASS / 5 XFAIL; B@0..3 428; R 104.
- calls.lua: mode B passes; mode A differs only in the private dump format at
  line 474 (verified by removing the binary-chunk block, then 0 diff), so the
  row moved to tests/known-different.tsv.

## Remaining risks

- `coroutine.wrap(chainObject)` and a chain object as the xpcall handler are
  rejected as non-functions before any resolution, as in PUC; only a direct
  pcall/xpcall target can reach the overflow path.
- Nothing can change a metatable between the two passes: neither pass
  allocates a collectable object, and growing the stack reallocates it
  without a GC step, so no finalizer runs in between.
- A cyclic chain is bounded by the stack, not by a fixed depth, as in PUC.
- Other interpreter backends (x86, arm, ppc, mips) still carry the one-level
  `lj_meta_call` call-site contract; only x64 GC64 and arm64 are ported. For
  them `lj_meta_call` is the one-level helper it was (`LJ_META_CALLCHAIN` in
  `lj_meta.h`): it never moves the stack, adds one argument, and a `__call`
  value that is not a function is an error; the recorder aborts on such a
  chain there. Those backends were not built.
