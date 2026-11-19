# Differences — JITLua-5.4 vs PUC Lua 5.4.9 and stock LuaJIT 2.1

User-facing list of deliberate divergences and known pending differences.
Every entry is recorded in this repository (MISSION.md, docs/phase0-status.md,
tests/known-bad.tsv, tests/known-different.tsv, docs/ffi-int-semantics.md). Features that are implemented
with PUC parity are not listed.

Status tags: `FORK` (deliberate fork decision), `IMPL-DEFINED` (the 5.4 manual
allows it / observable is implementation-defined), `PENDING` (known gap on
`wip-calls-vm` or a named VM item), `EXTENSION` (kept LuaJIT feature), `FIXED`
(historical known bug fixed; kept for traceability).

## Against PUC Lua 5.4.9

### Language and VM
- `FORK` String interning: LuaJIT interns every string; PUC does not intern long
  strings, so `%p`/`lua_topointer` identity after concat/gsub differs (design
  decision, Markus 2026-11-16; C probe `tests/capi` `probe_549`).
- `FORK` `string.dump` uses JITLua-5.4's private format; PUC 5.4.9 cannot load
  it, and mode R checks our own dump/reload round-trip.
- `FIXED` Arbitrary `_ENV` values: LuaJIT stored only a table as a function
  environment, so `load("return _ENV", nil, nil, 123)()` returned the global
  table and a non-table env was silently ignored. The function now carries the
  `_ENV` value itself (`GCfunc.envv`, any type): a table keeps the GGET/GSET
  fast path, any other value is indexed through the generic metamethod path in
  the interpreter and the JIT, and a nil env errors with PUC's "attempt to
  index a nil value (upvalue '_ENV')" -- before this fix that case SEGFAULTED
  in the VM (a NULL env table fed to the GGET/GSET lookup). `calls.lua` line
  359 now passes; tests `env_05_envvalue`, `env_06_nilenv` (the nil-env crash),
  `env_07_udenv` (userdata env, modes B,R).
- `FIXED` `__call` chain argument prepending (calls.lua lines 171/193): a
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
- `FIXED` pcall/xpcall C-call nesting bound: nested pcall/xpcall calls are
  bounded at PUC's LUAI_MAXCCALLS (200) with "C stack overflow" and a
  repeatedly erroring message handler ends in "error in error handling"
  (`tests/d54/err_04_ccall_bound.lua`).
- `FIXED` Cross-coroutine C-call nesting. PUC's `lua_resume` gives the
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
- `FIXED` pcall/xpcall are recorded in traces with an exact C-call counter
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
- `FIXED` Out-of-memory error on the inline path of a fast function (stock
  LuaJIT 2.1 too): `tostring(number)` and the string functions allocate
  without setting `L->top`, and `lj_err_mem` pushed the message at a stale top
  below the frame, into a live frame of a caller. Seen as a crash in the
  interpreter when the allocator fails before the collector's threshold is
  reached (`tests/capi` `oom_pcall`, the JIT-off arm).
- `FIXED` `__tostring` must return a string (5.4 `luaL_tolstring`). The
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
- `IMPL-DEFINED` Sparse-table border for runtime-built tables may differ: 5.4
  allows any border; LuaJIT's array-growth policy differs from PUC's alimit hint
  (`tbl_03_border_divergence`).
- `FIXED` `__gc` finalization for tables: implemented with PUC 5.4
  semantics. A table that receives a metatable with a `__gc` field is marked
  at that moment (a later added `__gc` does not mark it), resurrected for the
  call and collected on a later cycle, finalizers run in reverse marking
  order, an error in `__gc` is a warning, weak values are cleared before the
  call and weak keys in the next cycle, and `lua_close` runs the remaining
  finalizers. Implemented on x64 and arm64; the other backends need the same
  interpreter fast-path guard before they can be trusted for table
  finalizers (`tests/d54/gc_01_tbc_gc.lua`, `gc_02_table_finalizers.lua`).
- `FIXED` Tail-call error names: a tail call to a C function (fast function
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
- `PENDING` Return hook of a function that ends in a tail call to a C
  function: PUC calls the return hook for the Lua caller after the C function
  returns; here the caller returns through the continuation without a hook
  event, as it did when the frame was replaced.
- `FIXED` `debug.getinfo(level, "t").istailcall` is true for every Lua
  function entered by a tail call, with or without a hook, in the interpreter
  and in compiled code. `BC_CALLT`/`BC_CALLMT` marks the frame it sets up in
  the tag of the frame's function slot; trace exits rebuild frames with the
  mark; the `"tail call"` hook event reads the same mark. As in PUC, a C
  function reached by a tail call is an ordinary call, a function entered by
  a tail call has no name for `debug.getinfo` option `n`, and a traceback
  prints `(...tail calls...)` after its level
  (`tests/d54/debug_05_istailcall.lua`; mechanism in
  `docs/notes/istailcall.md`). x64 (GC64) and arm64 only.
- `FIXED` Debug names PUC's `db.lua` checks after its tail-call section:
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
- `IMPL-DEFINED` When an object referenced only from a dead stack slot is
  collected. The stack of a running Lua function is scanned up to the top of
  its frame (inherited from LuaJIT), so a value left in the argument slot of
  a finished call stays alive until the slot is reused or the function
  returns. PUC limits the scan to the live registers of the instruction that
  started the collection. `db.lua` line 913 waits in a loop for the finalizer
  of such an object and does not end here (the runner bounds the file at
  10 s; `tests/known-different.tsv`).
- `FORK` A stripped dump keeps no `linedefined`/`lastlinedefined` (both are 0
  after loading it); PUC's stripped dumps keep them (`db.lua` line 1002).
- `IMPL-DEFINED` Inside a `__close` handler on an error path, debug level 2 is
  the unwound Lua function; PUC shows the pcall C function
  (`close_03/04`; documented divergence).
- `IMPL-DEFINED` A yield from a `__close` handler crosses the C-level protected
  call; PUC resumes it (`close_04`; documented/accepted divergence).
- `FORK` C functions that marked a slot with `lua_toclose` and then yield close
  that slot at yield time, not when the frame "returns" after the resume: with
  no C continuation frame there is no later point to run `__close`. PUC keeps
  them pending across the resume. Observable in the order of `__close` calls
  relative to `coroutine.resume` (`tests/capi` `test_toclose`). An error (or
  yield) inside such a `__close` is raised in the coroutine at the yield, not
  after the resume; a yielding `__close` fails with "attempt to yield across a
  C-call boundary" instead of PUC's yieldable continuation.
- `FORK` The 5.4 C continuation API (`lua_callk`, `lua_pcallk`, `lua_yieldk`)
  is present, but LuaJIT has no C-level continuation frames: `k` is never
  called and `ctx` is ignored. `lua_pcallk` never returns `LUA_YIELD`;
  `lua_yieldk` with a non-NULL `k` raises "attempt to yield across a C-call
  boundary" instead of silently skipping the continuation. Plain
  `lua_yield` from a C function still works, including a tail yield
  (`tests/capi` `test_continuations`).
- `FIXED` The number metatable did not apply to integers outside the inline
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
- `FORK` `lua_getextraspace` is a function, not PUC's macro, and the
  `LUA_EXTRASPACE` area is appended to the end of `struct lua_State` instead of
  sitting before it: `(char *)L - lua_getextraspace(L)` differs from PUC. The
  semantics match PUC (per-thread area, a new thread copies the main thread's,
  freed with the thread; `tests/capi` `test_extraspace`), and the layout keeps
  the GC object pointer and every assembler offset unchanged. A module compiled
  against PUC's `lua.h` and linked against JITLua reads the wrong bytes and must
  be rebuilt against JITLua's headers (see the source-compatible FORK row
  above).
- `FIXED` A state created without the base library (`luaL_newstate()` with no
  `luaopen_base`) segfaulted in `var_lookup` on any chunk that names a global:
  the 5.4 `_ENV` special case reads the interned `_ENV` string from
  `gcroot[GCROOT_ENVSTR]`, which `lib_base` installed only when the base
  library was opened; `lj_record.c` read the same root. The string is now
  interned at state creation (`lj_state.c`), so parsing and recording work on
  bare states. Regression test `tests/capi` `test_bare_state` (reads, writes,
  loops, `lua_getglobal`/`lua_setglobal`, and a JIT-on hot global loop); the
  portable PUC 5.4.9 parity check is `tests/capi/bare_state_ref.c`.
- `FIXED` Weak-table JIT loop hang (`closure.lua:37`; stock LuaJIT 2.1 hangs
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

### Known JIT/performance rows (not semantic divergences)
- `FIXED` arm64 `bit.lshift/rshift/arshift/rol/ror` returned 0 for native and
  cdata; regression `cb2f6da`, fix `6e4d7bb9` (TMP0 clobber in checkint).
  See `docs/bug-bit-shift-arm64.md`; `tests/lib/bit-checkint.lua` is the
  regression test.

- `FIXED` `math.lua` mode B on x64: intermittent SIGSEGV/hang in the
  `math.random` statistics loops. x64 backend width bug: the checked
  `int64->int32` CONV left a sign extension in the register and HREF/NEWREF
  OR-ed the type tag into it, so negative int32 keys corrupted the hash
  part. See `docs/bug-math-random-jit.md`; `tests/lib/math-random-jit.lua` is
  the regression test.
- `IMPL-DEFINED` `heavy.lua` runs under a 4 GiB `RLIMIT_AS` cap in the
  `--include-heavy` stage; both sides then end in an allowed resource error
  (Lua 5.4 manual 3.4.7), but the reports differ: PUC stops with "not enough
  memory" at `#a=134217728` (peak ~2.0 GiB RSS) while LuaJIT stops with
  `heavy.lua:154: table overflow` at `#a=201326592` (peak ~3.3 GiB), and the
  `collectgarbage` byte counts differ in every mode. Excluded from the default
  corpus; see `tests/known-different.tsv`.
- `PENDING` Classic benchmarks slower than stock 2.1 (>10%): deltablue both
  arches (missing-metamethod trace loss), k-nucleotide x64
  (`__index`/string-key path); see `docs/perf-regression-2026-11-17.md` and
  `docs/bench-classic-2026-11-17.md`. spectral-norm x64 is ~4% (interleaved
  median of 9: stock 15.4 ms, ours 16.0 ms) and arm64 is at parity, below
  the threshold; the extra SLOAD flags and side traces are the 5.4
  integer/float loop model and are not redundant
  (`docs/notes/for-intfloat.md`).


## Against stock LuaJIT 2.1

### Added 5.4 language / VM surface
- `EXTENSION` 5.4 operators and bytecodes: `//`, `& | ~ << >>`, `<close>`,
  `OP_IDIV/MOD/BAND/OR/XOR/SHL/SHR/VARG/FORI/FORL`, 64-bit int constants.
- `EXTENSION` 5.4 `goto`/label scoping, `return`-ends-block grammar.
- `FORK` ASCII-only identifiers: bytes 128–255 are rejected; stock LuaJIT
  accepted them as identifier bytes (strict PUC 5.4 alignment, no switch).
- `FORK` `jit.version` and `luajit -v` read `JITLua-5.4 (LuaJIT 2.1.<relver>)`.
  Code that matches `^LuaJIT` to pick 5.1-era behaviour (luaunit keys its
  version branches off it) no longer takes those branches, which is right
  for 5.4 semantics; code that uses the match only to detect the `ffi`
  module should test `pcall(require, "ffi")` instead.

### Added 5.4 standard library / C API
- `EXTENSION` `utf8.*`, `string.pack/unpack`, `rawlen`, `math.type/
  tointeger/ult`, `package.searchers` two-result protocol and `require(name,data)`,
  `io` 5.4 read/seek/lines rules, `os.date/time` 5.4 field rules.
- `EXTENSION` 5.4 C API: `lua_newuserdatauv`, `lua_get/setiuservalue`,
  `lua_warning`/`warn`, `lua_setwarnf`, `lua_resume` 5.4 signature,
  `lua_closethread`/`lua_resetthread`, `lua_arith` with the `LUA_OP*`
  constants, `lua_toclose`/`lua_closeslot` (including closing on C return,
  error, and `lua_settop`), the PUC 5.4 `luaL_Buffer` layout with
  `luaL_buffinitsize`/`luaL_prepbuffsize`/`luaL_pushresultsize` and
  `luaL_buffaddr`/`luaL_bufflen`, `luaL_argexpected`, `luaopen_coroutine`,
  integer checks/return types, `luaL_addgsub/buffsub/pushfail`, and
  `luaL_tolstring/requiref/typeerror`. `luaconf.h` includes `<limits.h>` like
  PUC. The `luaL_Buffer` layout matches PUC 5.4 and `luaL_prepbuffer` is a
  macro over `luaL_prepbuffsize`; this changed the auxlib ABI, so C modules
  compiled against an older JITLua-5.4 auxlib must be recompiled.
- `EXTENSION` module-facing macros from PUC 5.4's headers are exported for C
  modules: `luaconf.h` also has `lua_numbertointeger`, `lua_str2number`/
  `lua_strx2number`, `lua_pointer2str`, `lua_number2strx`,
  `lua_getlocaledecpoint`, `LUAI_MAXCCALLS` and `luai_likely`/`luai_unlikely`
  (`l_likely`/`l_unlikely` under `LUA_CORE`/`LUA_LIB`); `lua.h` has
  `LUA_NUMTYPES`/`LUA_NUMTAGS`; `lauxlib.h` has `LUA_GNAME`,
  `LUA_PRELOAD_TABLE` and `LUAL_NUMSIZES`; `luaconf.h` has `LUAMOD_API`, and
  `lua_number2str` takes PUC's
  `(s, sz, n)` form and `lua_integer2str` uses `snprintf`. `luaL_checkversion`
  passes the fork ABI stamp (see the FORK row below) and
  `luaL_checkversion_` raises PUC's mismatch errors (it was a release-build
  no-op). `lua_setcstacklimit` is the PUC 5.4
  deprecated no-op returning `LUAI_MAXCCALLS` (200). The full comparison is in
  [docs/notes/capi-header-compat.md](notes/capi-header-compat.md).
- `FORK` The C API is **source-compatible** with PUC Lua 5.4, **not
  binary-compatible**: C modules must be rebuilt against JITLua's headers. The
  pseudo-indices keep LuaJIT's values (`LUA_REGISTRYINDEX` = -10000,
  `lua_upvalueindex(i)` = -10002-i, vs PUC's -LUAI_MAXSTACK-1000 and
  `LUA_REGISTRYINDEX-(i)`), `luaL_Buffer` is larger (`LUAL_BUFFERSIZE` is
  8192/BUFSIZ vs PUC's `16*sizeof(void*)*sizeof(lua_Number)`), and
  `lua_getextraspace` is a function with the area after `struct lua_State`.
  `luaL_checkversion()` passes a fork-specific ABI stamp
  (`LUAL_NUMABI` = `LUAL_NUMSIZES` + `LUAL_ABISTAMP`), so a module built
  against PUC 5.4's headers that calls it (`luaL_newlib` does) is rejected at
  load with "module built for a different Lua ABI; rebuild it against JITLua
  headers" instead of silently using the wrong slots. A raw `luaopen_*` that
  never calls `luaL_checkversion` cannot be caught; rebuild every module. The
  corpus C fixtures are built once per arm, PUC headers for the reference arm
  and JITLua headers for this fork (`tests/ref/build-puc54-libs.sh`), and each
  arm loads only its own build.
- `EXTENSION` `lua_getfenv`/`setfenv` remain present as LuaJIT extensions;
  PUC 5.4 removed them.

### Kept LuaJIT extensions
- `EXTENSION` `jit.*`, `bit.*`, `ffi`/cdata, `bcsave`, `-j`/`-O`/`-b` options.
- `EXTENSION` FFI int64/uint64 cdata and bit operations on cdata; intended
  semantics are in `docs/ffi-int-semantics.md` (tests `ffi_int_*`, modes B/R).
- `FORK` Native 5.4 integers in `bit.*` follow a hybrid rule (Markus,
  2026-11-17). A call whose arguments are all numbers (int32, widened/boxed
  int64, floats, numeric strings) keeps stock semantics: every operand wraps
  modulo 2^32 and the result is an int32 (`bit.band(2^32+1, 0xffffffff00000000)`
  → 0; exact 64-bit work uses `& | ~ << >>`). A call with a 64-bit cdata value
  operand converts native integers with their exact 64-bit value, the way
  stock converts a Lua number in a mixed call (`bit.band(uint64 max,
  (1<<40)|0xff)` → `1099511628031ULL`, as with an `int64_t` partner). Shifts
  and `tohex` decide by the value operand; a cdata shift count or digit count
  does not promote. `-joff` and `-jon` agree (pure calls compile, mixed calls
  with native int64 operands run in the interpreter). Details and mechanism in
  `docs/ffi-int-semantics.md`; test `tests/lib/bit-checkint.lua`.
- `EXTENSION` FFI source-literal suffixes `LL`, `ULL`/`LLU` and imaginary `i`
  (`1LL`, `1ULL`, `0x10ULL`, `12.5i`) are accepted when FFI is compiled;
  PUC 5.4 rejects them (`lex_03_ffi_suffix`).
- `EXTENSION` Inherited LuaJIT 3.0 syntax extensions (`doc/extensions.html`)
  are accepted where PUC 5.4.9 reports a syntax error, among them the short
  function expression `a -> b` / `|x| -> x*x`. Code that probes for the
  rejection sees the difference (`tests/d54/parse_arrow_shortfunc.lua`,
  mode A in `tests/known-different.tsv`).
- `EXTENSION` LuaJIT's pattern-matching implementation and its string-buffer
  optimizations remain; 5.4 pattern behaviors are covered by `str_03_patterns`.
- `EXTENSION` `string.dump` bytecode format and `-b`/`bcsave` are
  LuaJIT-specific; `dump_03_version` records the fork format.
- `EXTENSION` GC policy mode `LUAJIT_GC=speed|memory` (`src/lib_aux.c`,
  read in `luaL_newstate`, so every embedder that creates its states with it
  honours the variable; `lua_newstate` does not read it) and the equivalent
  `luajit -G speed|memory` option; `-G` overrides the environment, `-E`
  ignores it, unknown values are ignored silently. `speed` is the default
  300/200 (time-first, measured on both arches in
  `docs/notes/knuc-phase-align-2026-11.md`); `memory` sets pause 100 / stepmul 200
  (the Stage 0(a) row in `docs/gc-newgen-plan.md`), the RSS-first setting.
  Runtime `collectgarbage("setpause" / "setstepmul")` overrides either. The
  pause default is a deliberate divergence from stock LuaJIT 2.1's 200/200; it
  buys stock-parity k-nucleotide and a faster binary-trees for more peak RSS.
