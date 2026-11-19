# The __call chain (calls.lua lines 171/193)

Worktree `LuaJIT-5.4-callchain`, branch `callchain`, merged on top of main
`7e8e4bf9` (the tail-call-into-C recorder rework). Known-bad is empty; the
calls.lua mode-A row is now a known difference for the private dump format.

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
   stack. Per level it asks `lj_state_checkstack(L, n)` for one more slot
   relative to the width already counted, so a cyclic chain terminates in a
   catchable "stack overflow" instead of looping. A level without `__call`
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

- x64 `vmeta_call`/`vmeta_callt`: `RA = func+16`, `BASE = L->base`; the CALLT
  hint is kept as `KBASE-BASE` across the call. This offset must be computed
  before `lea CARG3`, because on POSIX `CARG3` aliases `BASE` (`rdx`). That
  clobber was the first implementation bug: the restored hint was garbage
  and tail calls through a chain executed the wrong bytecode.
- arm64 `vmeta_call`/`vmeta_callt`: `BASE`/`RA = func+16`, BASE reloaded from
  `L->base`. `vmeta_callt` keeps the CALLT pc (callee-saved x21) across the
  call; the merged `BC_CALLT2_Z` loads the caller frame pc only on the Lua
  path.
- Neither call site rewrites `L->top`: the `top` argument is the call's
  argument top, while `L->top` is a different, frame-relative value (at the
  call it can be below the func slot). The first implementation set
  `L->top = top+n`, which is wrong for this contract; the explicit
  `metanargs` field replaced it.

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

Red evidence on the unchanged tree: calls.lua aborts at line 187 under
`-joff` and `-jon` with `attempt to call a table value`; call_01 fails mode A
at the depth-2 call; call_02 fails both arms because the chain stops at the
first non-function level.

## Micro-benchmark (one pinned x64 box, base main 7e8e4bf9 vs head, interleaved)

20,000,000 calls of a depth-1 `__call` object in a hot loop, 7 alternating
runs each, medians (`-jon`):

    plain call   base 0.0280 s   head 0.0280 s   +0.0 %
    tail call    base 0.0300 s   head 0.0290 s   -3.3 %

Depth 1 is the unchanged single-level path.

## Gates (merged tree, main 7e8e4bf9)

- `tests/ci-box.sh`: all stages passed on x86_64 (pve pool) and aarch64.
- `tests/ci-local.sh --sanitizers-only`: `ci-local: OK` on both arches;
  d54 all modes: 295 PASS, 0 FAIL, 5 XFAIL.
- `tests/harness.sh --strict --mode all --timeout 120`: 353 PASS, 0 FAIL,
  7 XFAIL, 12 SKIP.
- d54: A+B 191 PASS / 5 XFAIL; B@0..3 424; R 104.
- calls.lua: mode B passes; mode A differs only in the private dump format at
  line 474 (verified by removing the binary-chunk block, then 0 diff), so the
  row moved to tests/known-different.tsv.

## Remaining risks

- Near the stack limit, `pcall(chainObject)` (the chain object as pcall's
  target, not a wrapper) can propagate "stack overflow" uncaught: the fast
  pcall has not installed its target frame when `vmeta_call` raises, while
  ordinary non-callable targets are caught by `lj_err_optype_call`'s dummy
  frame. The limit test therefore protects the call in a wrapper. Fixing this
  would need a comparable dummy frame for the stack-overflow path.
- A GC finalizer that mutates a metatable between the two passes could make
  the prepended objects differ from PUC's per-level retry view. No allocation
  happens in either pass, so only a stack-growing GC step could interleave;
  no test reaches that.
- A cyclic chain is bounded by the stack, not by a fixed depth, as in PUC.
- Other interpreter backends (x86, ppc, mips) still carry the one-level
  `lj_meta_call` call-site contract; only x64 GC64 and arm64 are ported.
