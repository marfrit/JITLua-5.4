# Differences — JITLua-5.4 vs PUC Lua 5.4.9 and stock LuaJIT 2.1

User-facing list of deliberate divergences and known pending differences.
Every entry is recorded in this repository (MISSION.md, docs/phase0-status.md,
tests/known-bad.tsv, docs/ffi-int-semantics.md). Features that are implemented
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
- `PENDING` `__call` chain argument prepending (calls.lua lines 171/193;
  VM work). A chain of callable tables must prepend one callable object per
  chain level. Mode A of calls.lua also hits the `string.dump` private-format
  FORK at its binary-chunk section (line 474), so calls.lua stays XFAIL in
  mode A for that reason too.
- `FIXED` pcall/xpcall C-call nesting bound: nested pcall/xpcall calls are
  bounded at PUC's LUAI_MAXCCALLS (200) with "C stack overflow" and a
  repeatedly erroring message handler ends in "error in error handling"
  (`tests/d54/err_04_ccall_bound.lua`).
- `FIXED` pcall/xpcall are recorded in traces with an exact C-call counter:
  `lj_record_ccallnest` emits the `ccallnest` increment and an exit-near-the-
  limit guard before the protected call, and the matching decrement on the
  trace's normal return from the pcall frame (any exit before that leaves the
  frame live for the interpreter's own decrement). `tests/bench/b5_pcall.lua`
  (x64 2M iterations): pcall 150->47 ms, xpcall 150->2.8 ms;
  `tests/d54/err_05_pcall_trace.lua` covers the penlight test-pretty shape.
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
- `PENDING` Tail-call error names: LuaJIT reuses the caller frame, so a manual
  module path reports `string.rep` where PUC reports the short `rep`
  (`err_02_tailname`; non-tail and pcall paths match).
- `PENDING` `debug.getinfo(1,"t").istailcall` is not true without a call hook;
  PUC reports true (`db.lua` line 619; Fable tail marks need a hook).
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
  be rebuilt against JITLua's headers (same ABI class as the `luaL_Buffer` note
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
  when a table becomes weak (or strong) after the trace was compiled. Cause,
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
  corpus; see `tests/known-bad.tsv`.
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
- `EXTENSION` LuaJIT's pattern-matching implementation and its string-buffer
  optimizations remain; 5.4 pattern behaviors are covered by `str_03_patterns`.
- `EXTENSION` `string.dump` bytecode format and `-b`/`bcsave` are
  LuaJIT-specific; `dump_03_version` records the fork format.
