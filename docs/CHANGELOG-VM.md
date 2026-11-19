# VM changelog — fixed divergences from PUC Lua 5.4.9

Former known bugs and pending items of JITLua-5.4 that are fixed, with the
technical notes kept for traceability. User-visible differences that remain are
in [DIFFERENCES.md](DIFFERENCES.md). Unless an entry says otherwise, the fixes
target x86_64 (GC64) and arm64.

## Language and VM

- Arbitrary `_ENV` values: LuaJIT stored only a table as a function
  environment, so `load("return _ENV", nil, nil, 123)()` returned the global
  table and a non-table env was silently ignored. The function now carries the
  `_ENV` value itself (`GCfunc.envv`, any type): a table keeps the GGET/GSET
  fast path, any other value is indexed through the generic metamethod path in
  the interpreter and the JIT, and a nil env errors with PUC's "attempt to
  index a nil value (upvalue '_ENV')" -- before this fix that case SEGFAULTED
  in the VM (a NULL env table fed to the GGET/GSET lookup). `calls.lua` line
  359 now passes; tests `env_05_envvalue`, `env_06_nilenv` (the nil-env crash),
  `env_07_udenv` (userdata env, modes B,R).
- `__call` chain argument prepending (calls.lua lines 171/193): a
  chain of callable tables now prepends one callable object per chain level,
  innermost first, until the first plain function, in the interpreter and in
  the recorder. The chain is bounded by the Lua stack like PUC (no fixed
  depth limit), so a cyclic or over-long chain raises the ordinary catchable
  "stack overflow", which pcall/xpcall directly on the chain catch like any
  other runtime error. calls.lua mode A now differs only in the `string.dump`
  private-format FORK at its binary-chunk section (line 474), which is listed
  in tests/known-different.tsv; mode B passes. Setting up such a call can
  grow and move the stack (`tests/d54/call_05_chain_stack_move.lua`). x64
  (GC64) and arm64 only; the other interpreters resolve one level, as before.
  See docs/notes/callchain.md.
- pcall/xpcall C-call nesting bound: nested pcall/xpcall calls are
  bounded at PUC's LUAI_MAXCCALLS (200) with "C stack overflow" and a
  repeatedly erroring message handler ends in "error in error handling"
  (`tests/d54/err_04_ccall_bound.lua`).
- Cross-coroutine C-call nesting. PUC's `lua_resume` gives the
  resumed thread the resumer's C-call count + 1, so the usable pcall depth
  inside a coroutine is lower by the resume nesting. The coroutine
  resume/wrap fast paths (`vm_x64`, `vm_arm64`), `ffh_resume` and the C API
  `lua_resume` apply that formula and raise the resume itself as "C stack
  overflow" at the 200 bound, before any coroutine state is mutated. The
  deltas against the top-level pcall depth match PUC 5.4.9 in `-joff`/`-jon`
  on both arches (`tests/d54/err_06_coro_ccallnest.lua`). The pcall frames a
  coroutine is suspended in are not counted again by the next resume and take
  nothing off the new count when they return, as in PUC
  (`tests/d54/err_10_resume_pending_pcall.lua`).
  The first attempt crashed at ~200 levels on x86_64 because its fast-path
  block loaded the resumer via `KBASE` (r15), which is the caller's bytecode
  constants base and survives the resume: the next string-key opcode read
  through a `lua_State` pointer (`lj_BC_TGETS`, `and 0xc(%rax)` with a small
  `rax`). It was not a C-stack limit of the fallback: the bound handler runs
  at depth and returns cleanly. `tests/d54/err_07_resume_chain.lua` guards
  the crash and probes 1000 nested resumes and wraps, which must end in a
  caught error on both arches.
  The close side is bounded too: `coroutine.close`, `lua_closethread` and the
  wrap-error close give the closed thread the closer's count + 1, and
  `lj_meta_tbccloseall` raises "C stack overflow" when that count is already
  at the bound and a `__close` handler is pending (PUC errors when the C call
  into the handler reaches it; with no pending handler PUC does not error).
  A deep close chain now ends in PUC's error at its 198th thread instead of
  exhausting the native stack (was SIGSEGV at depth 200000 on both arches),
  `tests/d54/err_09_close_chain.lua`. A close refused that way calls no
  handler and leaves no to-be-closed slot pending on the reset thread.
  The main thread also starts with `LJ_CCALLNEST_BASE` 3, PUC's standalone
  baseline, so the absolute bound now matches PUC without changing any delta:
  pcall depth 197, resume `err@1` at depth 198, close failure at the 198th
  thread. The closed thread is left with a count of zero, so a thread reset
  by `lua_closethread` starts like a new one.
  Evidence: `docs/notes/resume-chain-crash.md`.
- pcall/xpcall are recorded in traces with an exact C-call counter
  (x64 and arm64; other targets keep them out of traces). The recorder emits
  the limit guard after the call setup and stores each change of `ccallnest`
  as the first instruction behind the snapshot that adds or drops the pcall
  frame, so memory matches every state a trace can leave to: by a guard or by
  an error raised in compiled code. An out-of-memory error inside a compiled
  pcall is caught by that pcall. Design and path table:
  `docs/notes/spectral.md`. `tests/bench/b5_pcall.lua` (x64 2M iterations):
  pcall 150->47 ms, xpcall 150->2.8 ms. Tests:
  `tests/d54/err_05_pcall_trace.lua` (the penlight test-pretty shape),
  `tests/d54/err_06_pcall_trace_paths.lua`, `tests/capi` `oom_pcall`.
- Out-of-memory error on the inline path of a fast function (stock
  LuaJIT 2.1 too): `tostring(number)` and the string functions allocate
  without setting `L->top`, and `lj_err_mem` pushed the message at a stale top
  below the frame, into a live frame of a caller. Seen as a crash in the
  interpreter when the allocator fails before the collector's threshold is
  reached (`tests/capi` `oom_pcall`, the JIT-off arm).
- `__gc` finalization for tables: implemented with PUC 5.4
  semantics. A table that receives a metatable with a `__gc` field is marked
  at that moment (a later added `__gc` does not mark it), resurrected for the
  call and collected on a later cycle, finalizers run in reverse marking
  order, an error in `__gc` is a warning, weak values are cleared before the
  call and weak keys in the next cycle, and `lua_close` runs the remaining
  finalizers. Implemented on x64 and arm64; the other backends need the same
  interpreter fast-path guard before they can be trusted for table
  finalizers (`tests/d54/gc_01_tbc_gc.lua`, `gc_02_table_finalizers.lua`).
- Userdata finalizers installed during `lua_close`: LuaJIT registers
  finalizable userdata when the collector separates unreachable ones, and
  `lua_close` separated again after every finalizer round, so a `__gc` that
  created a finalizable userdata -- or gave `__gc` to another userdata -- ran
  again in the next round, up to the close loop bound, with user code running
  after teardown started. PUC 5.4 registers nothing while closing (GCSTPCLS in
  `luaC_checkfinalizer`): the object is freed without a second call. The
  separator's userdata branch now leaves everything alone while
  `g->gc.closing` is set, and `lua_close` separates once before setting the
  flag, so what already had `__gc` -- reachable objects included -- is still
  finalized exactly once like PUC's finobj list. Tables were already covered
  by the check in `lj_gc_checkfinalizer`; FFI cdata by the disabled finalizer
  table. Tests `tests/d54/udfin_01_close.lua` (modes B,R, 20 s timeout) and
  `tests/capi/udfinal.c` (same counters as the PUC 5.4.9 reference).
- Tail-call error names: a tail call to a C function (fast function
  or C closure) now keeps the Lua caller frame alive and enters the C function
  through a new `LJ_CONT_TAILRET` continuation frame that makes the caller
  return the C results. Error names resolve from the CALLT site, so LuaJIT
  reports the short `rep`/`move` like PUC 5.4, and `__call` resolving to a C
  function in tail position names the object (`err_02_tailname`,
  `err_04_tailcall_c`). Tail calls to Lua functions keep the frame-replacement
  path (constant stack depth); tail calls to C functions consume Lua stack,
  bounded by the C-call limit, like PUC. The caller frame is kept whole, a
  vararg frame included, so `debug.getlocal`/`debug.setlocal` at level 1
  inside the C function see the caller's locals. The trace recorder mirrors
  the same continuation frame, so traces keep recording such tail calls
  inline; a fast function that hands over to a metamethod (`tostring` ->
  `__tostring`) is not such a tail call and replaces its own frame as before
  (`err_08_tailcall_c_trace`). The mechanism and the model layout are in
  `docs/notes/tailname.md`. x64 (GC64) and arm64 only.
- `debug.getinfo(level, "t").istailcall` is true for every Lua
  function entered by a tail call, with or without a hook, in the interpreter
  and in compiled code. `BC_CALLT`/`BC_CALLMT` marks the frame it sets up in
  the tag of the frame's function slot; trace exits rebuild frames with the
  mark; the `"tail call"` hook event reads the same mark. As in PUC, a C
  function reached by a tail call is an ordinary call, a function entered by
  a tail call has no name for `debug.getinfo` option `n`, and a traceback
  prints `(...tail calls...)` after its level
  (`tests/d54/debug_05_istailcall.lua`; mechanism in
  `docs/notes/istailcall.md`). x64 (GC64) and arm64 only.
- Debug names PUC's `db.lua` checks after its tail-call section:
  metamethod frames are named without the `__` prefix (`index`, `add`, the
  bit operators included), the call of a generic `for` iterator is
  `for iterator`, a finalizer run by the collector is `metamethod '__gc'`;
  tracebacks take a nil message and skip levels like lauxlib
  (`...\t(skipping n levels)`); `nups` counts the upvalues of the closures
  made by `string.gmatch` and `coroutine.wrap`; `activelines` has the line of
  the function's `end`; code without debug info reports `(no name)` upvalues,
  `currentline` -1 and `?:-1:` positions; on x64, `coroutine.resume` of a
  coroutine ending in an error no longer crashes while a return hook is set
  (`tests/d54/debug_06_names.lua`).
- The number metatable did not apply to integers outside the inline
  47-bit range (boxed int64): after `debug.setmetatable(0, {__index = math})`,
  `(1):floor()` worked but `((1 << 50) + 3):floor()` raised, and `getmetatable`
  of such an integer returned nil (PUC returns the number metatable). The same
  representation leak made the C API report a box as userdata, and `<`/`<=` on
  a widened inline integer against a non-number skipped the metamethod
  (`lj_i64_compare`). Fixed in the interpreter (`itypemap`, `lj_meta_lookup`,
  `lj_obj_ptr`, `lua_getmetatable`/`lua_setmetatable`) and in the JIT
  (`lj_record_mm_lookup` and the `ff_getmetatable` fast function in
  `vm_x64.dasc`/`vm_arm64.dasc`). `lua_isuserdata`, `lua_touserdata`,
  `lua_topointer`, `luaL_testudata`/`luaL_checkudata`, `lua_rawlen` and
  `lua_rawequal` now treat a box as a number. Regression tests
  `tests/d54/i64_06_numbermt.lua` and `tests/capi/test_i64.c`.
- A state created without the base library (`luaL_newstate()` with no
  `luaopen_base`) segfaulted in `var_lookup` on any chunk that names a global:
  the 5.4 `_ENV` special case reads the interned `_ENV` string from
  `gcroot[GCROOT_ENVSTR]`, which `lib_base` installed only when the base
  library was opened; `lj_record.c` read the same root. The string is now
  interned at state creation (`lj_state.c`), so parsing and recording work on
  bare states. Regression test `tests/capi` `test_bare_state` (reads, writes,
  loops, `lua_getglobal`/`lua_setglobal`, and a JIT-on hot global loop); the
  portable PUC 5.4.9 parity check is `tests/capi/bare_state_ref.c`.
- Weak-table JIT loop hang (`closure.lua:37`; stock LuaJIT 2.1 hangs
  there too). A trace that reads from a weak table keeps its allocations, so
  the loop's GC check drives the collector, and the GC step at the loop head
  clears the dead stack slots, so a value the interpreter left there is not a
  GC root. A guard on the metatable and on its `__mode` field exits the trace
  when a table becomes weak (or strong) after the trace was compiled; the
  guard covers the table an entry is read from, the links of an `__index`
  chain and the metatable included (`weak_index_chain.lua`), and a side trace
  that reads a weak table makes its root trace clear the dead slots too
  (`weak_metatable_mode.lua`). Cause,
  fix and limits: `docs/bug-weak-table-jit-loop.md`; tests:
  `tests/d54/weak_*.lua`.
  Not a difference: a loop that allocates nothing never runs the collector, so
  a weak entry it only reads (`while x[1] do A = A+1 end`) stays. PUC 5.4 and
  `-joff` behave the same (`weak_noalloc_boundary.lua`).
- `__tostring` must return a string (5.4 `luaL_tolstring`). The
  conversion paths `tostring()`, `print()`, `string.format("%s")`, the C API
  `luaL_tolstring` and the standalone message handler now enforce it: a string
  result passes, a number is converted, anything else raises
  "'__tostring' must return a string" instead of passing the wrong value
  through. The C fast function validates the result (no tail call), the
  x64/arm64 asm `tostring` string path falls back when the string base
  metatable has `__tostring`, and the recorder leaves any `__tostring` call to
  the interpreter (a trace cannot check a tail-called result; no trace abort).
  `__name` from the value's metatable, per-type base metatables included,
  names the default rendering, and `luaL_getmetafield` returns the field type
  again (it returned a boolean, so the `__name` branch in `luaL_tolstring`,
  `luaL_typeerror` never fired). `print()` uses `luaL_tolstring` per argument
  like PUC 5.4.9 and no longer calls a replaced global `tostring`.
  `table.concat` and `..` stay non-`__tostring` paths. Tests
  `tests/d54/tostring_01..04`, the capi `tolstring` group; benchmark
  `tests/bench/b6_tostring.lua` (no-metamethod hot paths flat, the
  `__tostring` case +23 % interpreted and no longer traced); design and path
  table: `docs/notes/tostring54.md`.

## Known JIT/performance rows (not semantic divergences)

- arm64 `bit.lshift/rshift/arshift/rol/ror` returned 0 for native and
  cdata; regression `cb2f6da`, fix `6e4d7bb9` (TMP0 clobber in checkint).
  See `docs/bug-bit-shift-arm64.md`; `tests/lib/bit-checkint.lua` is the
  regression test.
- `math.lua` mode B on x64: intermittent SIGSEGV/hang in the
  `math.random` statistics loops. x64 backend width bug: the checked
  `int64->int32` CONV left a sign extension in the register and HREF/NEWREF
  OR-ed the type tag into it, so negative int32 keys corrupted the hash
  part. See `docs/bug-math-random-jit.md`; `tests/lib/math-random-jit.lua` is
  the regression test.
