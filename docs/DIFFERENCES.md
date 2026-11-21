# Differences — JITLua-5.4 vs PUC Lua 5.4.9 and stock LuaJIT 2.1

User-facing list of deliberate divergences and known pending differences.
Every entry is recorded in this repository (MISSION.md, docs/phase0-status.md,
tests/known-bad.tsv, tests/known-different.tsv, docs/ffi-int-semantics.md). Features that are implemented
with PUC parity are not listed.

Status tags: `FORK` (deliberate fork decision), `IMPL-DEFINED` (the 5.4 manual
allows it / observable is implementation-defined), `PENDING` (known gap, tracked
in tests/known-bad.tsv when a test shows it), `EXTENSION` (kept LuaJIT feature),
`REMOVED` (stock LuaJIT 2.1 surface that is not in the default build; a
compile-time switch brings it back).

Platforms: all VM and JIT changes target **x86_64 (GC64) and arm64** on Linux,
the two tested platforms. The other LuaJIT backends (x86, arm, ppc, mips and
non-GC64 builds) are not maintained and may lack individual 5.4 changes.
For x86_64 without GC64 that is concrete: `src/Makefile` picks `vm_x86.dasc`
(the VM for 32 bit GC references) whenever `LJ_FR2` is off, and that VM has no
handler for `BC_IDIV`, `BC_KI64`, `BC_TBC` or `BC_TBCCLO` and no `cont_tbc` or
`cont_tailret`. Such a build is now stopped by an `#error` in `lj_arch.h` that
names the missing pieces; before, it failed later and unexplained in buildvm
with `Error: undefined opcode BC_IDIV` (measured,
and the open ticket for the interpreter port: docs/notes/nogc64-2026-11-19.md).
The *object layout* of that configuration is maintained: `make layout-check`
(`tests/nogc64-layout.sh`, a stage of `tests/ci-box.sh`) compiles the GC object
headers for x86_64 in both reference layouts, so a field added to a GC object
cannot move a `GChead`-shared offset again; the non-GC64 arm of that check sets
`LUAJIT_GC64LESS_LAYOUT_PROBE`, which skips the `#error` and nothing else.  The 47-bit widened inline integers (ADR-001b step 6) are a GC64-only
representation: with 32 bit GC references the tag word has no payload bits, so
integers outside int32 always use the interned box there.

Fixed divergences, i.e. former known bugs with their technical notes, are in
[docs/CHANGELOG-VM.md](CHANGELOG-VM.md).

## Against PUC Lua 5.4.9

### Language and VM
- `PENDING` An integer argument that has no integer value is truncated or
  saturated instead of raising "number has no integer representation":
  `("hello"):sub(1.5)` is `"hello"`, `string.char(65.5)` is `"A"`, and a
  numeric string beyond the int64 range is converted the same way.
  `string.rep` is the exception in the interpreter, which rejects a
  non-integral count; compiled code truncates it there too, so a loop
  recorded with the count 2 returns `"xx"` for 2.5 where the interpreter
  raises.
- `PENDING` `math.max` and `math.min` accept numeric strings; PUC compares the
  arguments as they are and raises "attempt to compare string with number".
- `PENDING` A numeric `for` loop with an integer start, limit or step outside
  the int32 range runs as a float loop (the VM's loop instructions count in
  int32 or in doubles, and `lj_meta_for` converts such a value). The loop
  variable is then a float: `for i = 2147483646, 2147483649 do print(i) end`
  prints `2147483646.0` and so on, and `for i = 1, math.maxinteger` has a
  float `i` from the first iteration. From 2^53 on the values are rounded
  and the loop does not count correctly:
  `for i = math.maxinteger - 2, math.maxinteger do ... end` does not end
  (PUC: three iterations). Compiled code and the interpreter agree
  (`tests/d54/for_01_int64_control.lua`, a `tests/known-bad.tsv` row for the
  comparison with PUC). The PUC suite checks this in `nextvar.lua`, one of
  the files the harness skips.
- `PENDING` A numeric string as a `for` bound is converted with the
  int32-or-double rule: a decimal integer string outside int32 makes the loop
  a float loop (PUC: integer loop), and a hexadecimal one does not wrap
  (`for i = 1, "0xffffffffffffffff"` runs; PUC runs it zero times).
- `IMPL-DEFINED` String arithmetic is part of the VM's arithmetic fallback;
  the string metatable has no `__add`, `__sub`, ... entries (PUC implements
  the coercion through them, so there it can be inspected and replaced).
- `FORK` String interning: LuaJIT interns every string; PUC does not intern long
  strings, so `%p`/`lua_topointer` identity after concat/gsub differs (design
  decision, Markus 2026-11-16; C probe `tests/capi` `probe_549`).
- `FORK` `string.dump` uses JITLua-5.4's private format; PUC 5.4.9 cannot load
  it, and mode R checks our own dump/reload round-trip.
- `IMPL-DEFINED` Sparse-table border for runtime-built tables may differ: 5.4
  allows any border; LuaJIT's array-growth policy differs from PUC's alimit hint
  (`tbl_03_border_divergence`).
- `PENDING` A return hook without a call hook (`debug.sethook(f, "r")`) gets
  no return event for some of the fast functions implemented in assembler
  (measured: `tostring`, `string.sub`; `type` and `math.abs` do report):
  their return event is fired from a note the call event leaves, and no call
  event is dispatched without the call mask. With `"cr"` the events equal
  PUC's (`tests/d54/debug_07_tostring_hook.lua`).
- `PENDING` Return hook of a function that ends in a tail call to a C
  function: PUC calls the return hook for the Lua caller after the C function
  returns; here the caller returns through the continuation without a hook
  event, as it did when the frame was replaced.
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
- `FORK` `lua_getextraspace` is a function, not PUC's macro, and the
  `LUA_EXTRASPACE` area is appended to the end of `struct lua_State` instead of
  sitting before it: `(char *)L - lua_getextraspace(L)` differs from PUC. The
  semantics match PUC (per-thread area, a new thread copies the main thread's,
  freed with the thread; `tests/capi` `test_extraspace`), and the layout keeps
  the GC object pointer and every assembler offset unchanged. A module compiled
  against PUC's `lua.h` and linked against JITLua reads the wrong bytes and must
  be rebuilt against JITLua's headers (see the source-compatible FORK row
  above).

### Known JIT/performance rows (not semantic divergences)

- `IMPL-DEFINED` `heavy.lua` runs under a 4 GiB `RLIMIT_AS` cap in the
  `--include-heavy` stage; both sides then end in an allowed resource error
  (Lua 5.4 manual 3.4.7), but the reports differ: PUC stops with "not enough
  memory" at `#a=134217728` (peak ~2.0 GiB RSS) and LuaJIT also stops with
  "not enough memory", at `#a=268435456` (`collectgarbage'count'` ~2.15 GiB).
  With a 14 GiB cap PUC stops at `#a=536870912` and LuaJIT at
  `#a=1073741824` (~8.59 GiB counted on both sides). The array part now grows
  past the old 2^27+1 limit under GC64 (up to 2^31-1 slots, PUC MAXABITS=31);
  the remaining difference is only the stop size and the per-MiB counters.
  Excluded from the default corpus; see `tests/known-different.tsv`.

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

### Removed from stock LuaJIT 2.1
- `REMOVED` The Lua 5.1 leftovers are not in the default build: `gcinfo`,
  `module`, `newproxy` and `unpack` in `_G`; `foreach`,
  `foreachi`, `getn` and `maxn` in `table`; `loaders` (the alias of
  `searchers`) and `seeall` in `package`. None of them is Lua 5.4 — 5.4 has
  `load`, `table.unpack`, `collectgarbage("count")`, `pairs`/`#` and
  `package.searchers` — and none is a deliberate extension of this fork.
  `make CFLAGS=-DLUAJIT_ENABLE_51COMPAT` builds them back, unchanged: the
  macro `LJ_51COMPAT` (`src/lj_arch.h`) guards the definitions in
  `lib_base.c`, `lib_table.c` and `lib_package.c` with `#if LJ_51COMPAT`, and
  `src/host/buildvm_lib.c` knows that line, so the generated library tables
  follow the switch. Only `newproxy` has no 5.4 equivalent from Lua; the
  profiler's at-exit sentinel in `jit/p.lua` uses a table with `__gc`.
  Kept on purpose: `jit.*`, `bit.*`, `ffi`, `string.buffer`, `table.new`,
  `table.clear`, `getfenv`, `setfenv`. Tests:
  `tests/d54/compat51_01_51names_absent.lua` (default build, modes A, B, R)
  and `tests/lib/compat51-check.lua` with its build script
  `tests/lib/compat51build-d54.sh` (a `tests/ci-box.sh` stage on both
  arches); the two d54 files that build userdata with `newproxy`
  (`env_07_udenv`, `udfin_01_close`) report a skip in the default build and
  run in that stage. `loadstring` stays in every build: Penlight 1.14
  decides "this is LuaJIT" from `tostring(assert)` containing `builtin` and
  then probes with `loadstring(...)`; without it its app/class scripts stop
  with rc=1.

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
