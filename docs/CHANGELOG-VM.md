# VM changelog — fixed divergences from PUC Lua 5.4.9

Former known bugs and pending items of JITLua-5.4 that are fixed, with the
technical notes kept for traceability. User-visible differences that remain are
in [DIFFERENCES.md](DIFFERENCES.md). Unless an entry says otherwise, the fixes
target x86_64 (GC64) and arm64.

## Language and VM

- String to number conversion (Lua 5.4 numeral rules), one conversion for the
  interpreter, the library and compiled code. Four defects, all in the two
  functions every such conversion goes through (`lj_strscan_scan`, and
  `str2num` in `lj_meta.c`): `"inf"`, `"infinity"` and `"nan"` were accepted
  as numbers in arithmetic, as library arguments and as `for` bounds (PUC:
  not numerals); `"0x1e" + 0` was the float 30.0, because the hex digit `e`
  was taken for an exponent; a string denoting an integer outside int32 next
  to a float operand (`"9223372036854775807" + 0.5`) returned the integer
  operand; and the always-double conversion (`lj_strscan_num`: library
  number arguments, and `IR_STRTO` in compiled code) gave -0.0 for `"-0"`
  and 1.8e19 for `"0xffffffffffffffff"`, where 5.4 converts the integer 0
  and the wrapped integer -1. The last one made `1 / s` and `s ^ 1` differ
  between the interpreter and a trace. Also: `%d`/`%x` convert a numeric
  string exactly (`string.format("%d", "9223372036854775807")` raised), and
  the recorder of the string functions no longer converts a string argument
  in place before the function runs (`("hello"):sub("0xffffffffffffffff")`
  returned `"hello"` in the recorded iteration, `"o"` otherwise).
  `tests/d54/numeric_08_strcoerce.lua`.
- `string.format("%s", v)` in compiled code with an integer outside int32
  wrote the number without looking for a `__tostring` in the number
  metatable; the interpreter called it. The lookup is recorded now, and with
  a method the conversion is left to the interpreter, as for `tostring`.
  `tests/d54/tostring_09_format_i64mt.lua`.
- String arithmetic subtypes (Lua 5.4): a numeric string that denotes an
  integer (`"2"`, `"0x10"`) is an *integer* operand in 5.4 (`luaV_tonumber_`),
  so `5 + "2"` is the integer 7, `- "2"` the integer -2, `5 % "2"` the integer
  1 -- above 2^53 the value itself changes, not only the subtype. The
  interpreter already did this (`lj_meta_arith`), but the recorder emitted
  `IR_STRTO` (float-only) for every string, so JIT-compiled `+ - * %` and
  unary `-` gave a float where PUC gives an integer. A traced float path
  cannot be guarded: the slot may hold `"2.0"` at record time and `"2"` at
  run time (or vice versa), flipping the subtype -- and the value above
  2^53 -- under a committed trace, and `IR_STRTO` leaves no string form to
  guard on. So a string operand now leaves those five operations to the
  interpreter (`lj_trace_err` `BADTYPE`, the same escape as the existing
  i47w/i64 punts); `/` and `^` keep the traced `IR_STRTO` path because 5.4
  gives a float there for every string form. That the STRTO double is the
  value the interpreter computes holds since the string-to-number entry
  above; before it, `"-0"` and a wrapping hexadecimal integer differed.
  `tests/d54/numeric_05_strarith.lua` (both operand orders, hex, whitespace
  and exponent strings, values above 2^53, non-numeric strings, and the
  reverse `"2.0"`-then-`"2"` case) passes modes A, B@0..3 and R on x86_64
  and arm64; the pure-numeric arithmetic path is untouched. A loop with such
  an operation is not compiled: the recorder aborts until the loop is
  blacklisted (11 attempts measured), an inner loop without string
  arithmetic stays compiled, and a loop that sees a string operand only
  later keeps its trace and leaves it at that operand.
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
- Array parts above 2^28 slots: with the array limit at 2^31-1 slots under
  GC64 the x64 interpreter (`shl RCd, 3` in TGETV/TGETB/TGETR/TSETV/TSETB/
  TSETR/TSETM) and the x86 and arm64 backends (a constant index fused as
  `8*index` in an `int32_t`) scaled the index in 32 bits: `t[2^29+n]`
  addressed slot `n`, and a constant index from 2^28 on addressed memory
  below the array on x86_64. All of them scale in 64 bits now
  (`tests/lib/array-huge.lua`, a 4.3 GiB table, in `tests/ci-box.sh`;
  docs/notes/asize64.md).
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
- Integer equality in compiled code when a 64-bit result is inside the int32
  range. A trace carries the result of 64-bit integer arithmetic as an int64
  value, and only a result that fit int32 *while the trace was recorded* is
  narrowed under a guard; the other direction has no guard, so the same
  instruction can later produce a value inside int32 (an accumulator that
  passes through 0, `a[i] + b[i]` recorded on an iteration where the sum
  overflowed int32). `==`, `~=` and `rawequal` between such a value and an
  int32 value were decided from the two IR types, as "never equal":
  `local x = a[i] + b[i]; if x == 0 then` missed every zero once the loop was
  compiled, in all JIT arms on x86_64 and arm64. `lj_record_objcmp` now
  compares the 64-bit values (and `rawequal(int64, float)` compares exactly,
  as the equality bytecodes already did). The same state at the start of a
  side trace: the slot types come from the parent's snapshot, the stack from
  the exit handler, which writes an int64 inside int32 as an int32; the code
  after a loop that was left with such a value compared it wrongly and used
  it as a hash key under a guard that always failed. `rec_setup_side_i64`
  narrows such a slot under a guard before the first instruction is recorded.
  `rec_check_slots` in the assert build is strict again (it had been relaxed
  for exactly this state), and the assert build runs the d54 corpus with
  `-Ohotexit=1` in `tests/ci-box.sh` and `tests/ci-local.sh`. The
  representation rule as it really holds is at the top of `src/lj_record.c`.
  Test `tests/d54/i64_08_int32_reentry.lua` (red before in every JIT arm of
  the plain build); `tests/d54/i64_07_wrap_reentry.lua` for the wrap shapes.
- A numeric `for` loop with an integer control value outside int32, entered
  in compiled code. The interpreter runs such a loop as a float loop
  (`lj_meta_for` converts the value; see `docs/DIFFERENCES.md`). The recorder
  did the conversion on the stack and then used the slot's existing int64
  reference as if it were an int32: `for j = 2147483646, 2147483649` inside
  a hot loop ran 240 times in 200 rounds instead of 800, and the assert
  build stopped at "bad FORI argument type". `rec_for` now loads such a
  slot before the conversion and converts the reference the way
  `lj_meta_for` converts the value, under a guard that the value is outside
  int32 (a value inside stays an integer there). Test
  `tests/d54/for_01_int64_control.lua`, red before in every JIT arm; its
  comparison with PUC is the known-bad row for the float loop itself.
- The return hook of `tostring` after a `__tostring` call. The fast function's
  return event is fired from a note its call event leaves; the call event of
  the metamethod cleared it, so `tostring(obj)` had a call event and no return
  event. `lj_ffh_tostring` keeps the note across the call
  (`tests/d54/debug_07_tostring_hook.lua`).
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
  `table.concat` and `..` stay non-`__tostring` paths. A `__tostring` stored
  into a basic type's metatable later is seen by compiled code as well (the
  recorder records the lookup; a compiled store of the key clears the
  negative cache bit), and `string.format("%s")` calls the string metatable's
  method for a string argument. Tests
  `tests/d54/tostring_01..05`, the capi `tolstring` group; benchmark
  `tests/bench/b6_tostring.lua` (no-metamethod hot paths flat, the
  `__tostring` case +23 % interpreted and no longer traced); design and path
  table: `docs/notes/tostring54.md`.
- A stack overflow raised while the message handler itself is overflowing
  the stack was reported as the handler's own "stack overflow". PUC reports
  exactly this situation (luaD_growstack failing at ERRORSTACKSIZE) as
  "error in error handling" (ldo.c luaD_errerr). The first overflow grows the
  stack to LJ_STACK_MAX+LJ_STACK_ERREX for the handler; a second overflow in
  the handler then hit `lj_state_growstack`'s abort branch, which threw
  LJ_ERR_STKOV. It throws LJ_ERR_ERRERR now. `xpcall(loop, loop)` returned
  `false, "stack overflow"`; PUC returns `false, "error in error handling"`
  (`tests/d54/err_11_errerr_msg.lua`; the PUC suite file cstack.lua checks
  this on line 29).

## Known JIT/performance rows (not semantic divergences)

- Classic benchmarks against stock LuaJIT 2.1: none is more than 10 % slower.
  This closes the `PENDING` row `docs/DIFFERENCES.md` had for deltablue,
  k-nucleotide and spectral-norm. Measured 2026-11-20 with
  `tests/bench/classic/run-interleaved.py`, arms interleaved, median of 9, one
  host per architecture; stock/ours, above 1 is faster than stock:

  | benchmark | x86_64 stock ms | x86_64 | arm64 stock ms | arm64 |
  |---|---:|---:|---:|---:|
  | nbody | 6.8 | 0.971 | 2.1 | 0.731 (see below) |
  | spectral-norm | 15.3 | 0.962 | 3.9 | 0.990 |
  | fannkuch-redux | 67.6 | 1.081 | 13.4 | 0.987 |
  | binary-trees | 929.4 | 1.102 | 232.5 | 0.942 |
  | fasta | 9.6 | 1.039 | 3.3 | 1.013 |
  | deltablue | 18854.1 | 0.991 | 3628.4 | 1.086 |
  | scimark | 31277.7 | 1.058 | 25840.6 | 0.984 |
  | k-nucleotide | 63.1 | 0.988 | 17.1 | 0.948 |
  | regex-dna | 59.4 | 0.951 | 12.3 | 0.917 |

  The arm64 host is shared and its short rows are runs of a few milliseconds.
  nbody alone on that host, median of 11: 0.982 at the set's size (1.3 ms),
  0.993 and 0.997 at 10 and 100 times the iterations; an empty script starts in
  0.36 ms (stock) and 0.38 ms. The 0.731 of the set is not the benchmark.
  - **deltablue**: the missing-metamethod trace aborts came from a
    miscompilation in the alias analysis (`src/lj_opt_mem.c`), fixed by
    `60cc7371`; what was left was the weak-table guard, fixed by `ccd4dc0d`
    (merge `8d4b3740`). History and the earlier measurements (0.964, 1.018,
    1.025 with the JIT on, 0.989 with it off): `docs/notes/deltablue.md`. The
    causes named in `docs/perf-regression-2026-11-17.md` were retracted by
    that note itself.
  - **k-nucleotide**: not the `__index`/string-key path. Parity came from the
    default pause 200 → 300 (`7a85607e`, the GC policy `EXTENSION` row of
    `docs/DIFFERENCES.md`; `docs/notes/knuc-phase-align-2026-11.md`).
  - **spectral-norm x86_64**: about 4 % slower, below the threshold, and
    nothing was changed for it: 0.962 in the set above, and with
    `tests/bench/spectral-measure.py` on the same day 0.958, 0.977 and 0.961
    (medians of 9), as in `docs/notes/spectral.md` (median of 7: 15.4 against
    16.0 ms). The **0.499** that a classic-set run once reported for it
    (`docs/notes/deltablue.md`) was the runner, not the tree: it timed with
    `subprocess.run(timeout=...)`, which waits for the child by polling with
    sleeps that double up to 50 ms, so the end of a run was seen 15.5, 31.5,
    63.5, 113.5, ... ms after its start. Stock (15.4 ms) was seen at 16 ms and
    this tree (16.0 ms) at 32 ms; repeated in one job with the old runner:
    16.1 against 32.1 ms. The runner waits without a timeout now and checks the
    exit status. The extra SLOAD flags and side traces of this benchmark are
    the 5.4 integer/float loop model and are not redundant
    (`docs/notes/for-intfloat.md`).
  - The 2026-11-17 tables in `docs/bench-classic-2026-11-17.md` are kept as
    dated snapshots (their runner reads the child's output through pipes,
    which ends the wait when the child exits).
- arm64 `bit.lshift/rshift/arshift/rol/ror` returned 0 for native and
  cdata; regression `ea371c60`, fix `9cc89969` (TMP0 clobber in checkint).
  See `docs/bug-bit-shift-arm64.md`; `tests/lib/bit-checkint.lua` is the
  regression test.
- `math.lua` mode B on x64: intermittent SIGSEGV/hang in the
  `math.random` statistics loops. x64 backend width bug: the checked
  `int64->int32` CONV left a sign extension in the register and HREF/NEWREF
  OR-ed the type tag into it, so negative int32 keys corrupted the hash
  part. See `docs/bug-math-random-jit.md`; `tests/lib/math-random-jit.lua` is
  the regression test.
- String-sweep prefetch (`LJ_STR_PREFETCH`, x86_64 default 16, off on other
  targets; `-DLJ_STR_PREFETCH=N` overrides, `N=0` is the unmodified
  collector): `gc_sweepstr` is a pointer chase over the intern table, one
  cache miss per interned string, so the chain head a few buckets ahead is
  prefetched as a hint -- no layout and no semantics change. x86_64, one box,
  base and head interleaved in one job, median of 7: k-nucleotide 70.35 ->
  68.35 ms (-2.84%), binary-trees 855.7 -> 843.7 ms (-1.40%), lpeg -0.45%,
  lua-cjson flat, the rest within noise; 10 alternating pairs put
  k-nucleotide at -2.94% with the head faster in 10/10. Off on arm64 because
  the hint costs there. `tests/bench/gc-strsweep.sh` reproduces the A/B,
  `tests/d54/gc_05_strsweep.lua` guards the sweep.
