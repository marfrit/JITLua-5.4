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
The Lua 5.4 numeric-`for` rules are implemented in the x86_64 and arm64 VMs
only; the other backends compile but keep LuaJIT's 2.1 coercion and would
misread a wide loop's state object.
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
- `IMPL-DEFINED` The C-call bound ("C stack overflow" at 200 nested C
  calls, PUC `LUAI_MAXCCALLS`) counts the same calls as PUC wherever a call
  really passes through C: pcall/xpcall, coroutine resume and close, and
  every call from a C function or the C API into the VM. PUC also counts
  calls that are C calls only in its own implementation. They differ here:
  - A metamethod or `__close` handler called by the interpreter or by
    compiled code is not a C call. A recursion through one (an `__index`
    function that indexes again) ends in "C stack overflow" after about 200
    levels in PUC and in the ordinary "stack overflow" at the Lua stack limit
    here. For the same reason a `__close` handler at the last level below the
    bound runs here, while PUC refuses it.
  - pcall and xpcall are refused at and above the bound; PUC lets them use
    the 20 extra levels while a "C stack overflow" is handled. The other
    calls from C can use them here, too.
  - `__close` handlers that run while an error unwinds to a protected call
    made from C (`lua_pcall`), fail and start the next round of handlers are
    refused with "error in error handling" once they nest too deep on the C
    stack (PUC unwinds the C stack first and keeps going). Under a `pcall`
    or `xpcall` called from Lua the handlers run after the C stack is
    unwound, as in PUC.
  - FFI callbacks are not counted.
- `IMPL-DEFINED` Stack-overflow depth: PUC grows to `LUAI_MAXSTACK`
  (1000000 slots, plus the error stack) before failing, this tree caps at
  `LJ_STACK_MAX` (plus `LJ_STACK_ERREX` for the handler), so a recursive
  function dies far earlier here, and the JIT-on and JIT-off arms differ by
  a frame or two. The PUC suite file `cstack.lua` prints the depth (its
  "final count" lines), so its modes cannot match; the
  message it asserts on line 29 ("error in error handling") is fixed
  (`tests/d54/err_11_errerr_msg.lua`). Rows in `tests/known-different.tsv`.
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
- `FORK` `collectgarbage("count")` after clearing a weak kv table
  (`gc.lua:475/487`, now passing). The persistent part is fixed: the global
  temp buffer is released in the atomic phase instead of halved, so after the
  table is cleared the count drops back (the `gc.lua:487` assertion passes on
  both arches and both JIT modes). Two residuals remain, both observables:
  `count` reports LuaJIT's allocation grain, so the absolute figures differ
  (`after collect` 4093 vs 4096 KB, `final` -2.8 vs +0.35 KB relative to the
  baseline, x86_64 and aarch64, `-joff` and `-jon`); and while a long string
  is being built, the builder buffer is counted (after fill 12288 vs 8192 KB),
  because LuaJIT builds into its reused global temp buffer, freed at the next
  atomic, whereas PUC's builder memory is not counted. Freeing the buffer per
  call would match that instant but reallocates megabytes per string build;
  keeping it is the cheaper allocation strategy. `tests/lib/gc-count-weak-repro.lua`.
- `FORK` A stripped dump keeps no `linedefined`/`lastlinedefined` (both are 0
  after loading it); PUC's stripped dumps keep them (`db.lua` line 1002).
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
- `IMPL-DEFINED` How deep syntactic nesting may go. PUC has no fixed nesting
  limit: its parser recurses and the C-call bound (`LUAI_MAXCCALLS`, 200) stops
  it, so `load("return " .. string.rep("(", 500) .. "2" .. …)` fails with
  "C stack overflow", and 500 nested `do … end` blocks fail the same way. This
  tree counts nesting with a counter (`synlevel_begin`, `LJ_MAX_XLEVEL`) and
  rejects the expression shapes with its own register/constant limits
  ("chunk has too many syntax levels", "function or expression needs too many
  registers near …"). The message *wording* of the shared limits now follows
  PUC ("too many X (limit is N) in main function near …", `err_limit` in
  `src/lj_parse.c` with `LJ_ERR_XLIMM/XLIMF`), and
  `tests/d54/parse_02_limit_msgs.lua` prints the whole set; the depth at which
  a nesting shape is refused is the part that cannot match, because PUC
  measures it in C frames. `errors.lua`'s `testrep` (lines 636-659) accepts
  both: every message carries "too many" or "overflow".
- `IMPL-DEFINED` Registers per function: a frame has at most 250 slots here
  (`LJ_MAX_SLOTS`), PUC's 255 (`MAXREGS`); past that, both fail with
  "function or expression needs too many registers". Slot numbers are 8 bit
  in the bytecode operands, the JIT's snapshots and its trace stack
  (`LJ_MAX_JSLOTS`, also 250), and a call needs its frame link slots (two
  with `LJ_FR2`) above the last argument, so a frame stops short of 256.
- `IMPL-DEFINED` How many collection cycles a program triggers. The 5.4 manual
  leaves the pacing to the implementation, and this collector's pause, step
  work and accounting differ (see the basic-step and GC policy rows). The
  suite helper `tracegc.lua` writes one `.` to stderr per finished cycle, so
  `locals.lua` prints a different number of dots than PUC (mode A row in
  `tests/known-different.tsv`).
- `IMPL-DEFINED` Constants per function: at most 65536 numbers and 65536
  other constants (strings, nested functions, table templates) in one
  function, "too many constants (limit is 65536) in main function"; PUC
  allows 33554431 ("too many constants (limit is 33554431)", `lcode.c` addk,
  `MAXARG_Ax`). The bytecode addresses a constant with a 16-bit operand
  (`BCMAX_D`); PUC reaches its larger table through `OP_LOADKX` +
  `OP_EXTRAARG`. Matching it would mean wider constant operands in the
  bytecode format, both VMs, the recorder and the dump format.
- `IMPL-DEFINED` Jump distance: a jump may span at most 32767 instructions;
  longer ones fail to load with "control structure too long" (for example
  32767 `break`s in one loop body, or 40000 backward `goto`s to one label).
  PUC's signed jump operand has 25 bits. Same reason as the constants: the
  16-bit jump operand of the bytecode format. Only jumps that are long in
  the code itself count: a jump to a jump is threaded to the final target
  only where that distance fits.

- `IMPL-DEFINED` The default pause/stepmul are LuaJIT's measured speed policy
  300/200, not PUC's 200/100 (a deliberate tuning decision taken 2026-11-19;
  not a source semantic). Only the first deprecated `setpause`/`setstepmul`
  call and an `incremental` call that does not set them observe the defaults;
  every later call follows PUC's return and application rules exactly
  (`tests/d54/gc_09_params.lua`). A program that does not depend on the first
  return of the deprecated setters sees no difference.
- `FORK` `IMPL-DEFINED` GC mode and the size of a basic step.
  The standalone interpreter starts in PUC's generational mode (`lua.c` calls
  `lua_gc(LUA_GCGEN)` after `luaL_openlibs`); a state created with
  `luaL_newstate` starts incremental, as in PUC's lauxlib. The mode string and
  the previous-mode return of `collectgarbage("generational")` /
  `"incremental"` are exact; only the mode flag is stored because this tree
  has a single incremental collector. PUC's `pause`/`stepmul` parameters are
  applied with PUC's storage rule (`lgc.h` `setgcparam`: divided by 4 in one
  byte, `getgcparam`: multiplied by 4), so `setpause`/`setstepmul` return the
  previous PUC value, including the byte truncation of large values (1234 ->
  208, 5678 -> 556), and `"incremental", pause, stepmul` applies non-zero
  values. `FORK`: `incremental`'s `stepsize` and `generational`'s
  `minormul`/`majormul` are accepted and type-checked, but this collector has
  no corresponding knobs (single incremental collector; a real generational
  collector is Stage 3 of `docs/gc-newgen-plan.md`). `restart` resets the debt
  to 0 as PUC's `lua_gc(LUA_GCRESTART)` does; because LuaJIT paces with a
  threshold, the threshold still follows the pause policy for the CLI's
  `-1` restart (total otherwise), rather than PUC's debt-only pacing. The work of a basic step
  also differs: `lj_gc_step()` runs `GCSTEPSIZE/100*stepmul*4` bytes of
  collector work (~2 KB at default stepmul 200, `src/lj_gc.c`), while PUC's
  basic step is a fixed-size PUC work unit. A stepmul that stores as 0 (PUC
  `setstepmul` value 1..3) still does one collector step, like PUC's
  `incstep` `| 1`, never a full collection. A weak entry in an old all-weak
  table therefore dies after more steps here; with a large
  `collectgarbage("setstepmul", ...)` it dies in one basic step and reports
  the finished cycle, so only the quantum differs, not the weak-table
  semantics. The manual fixes neither quantum nor PUC's object ages (`old`,
  `touched1`, `touched2`, `survival`), which are not observable here. What a program can
  observe from the generational section of `gengc.lua`: the mode string returned
  by `collectgarbage("generational")`/`("incremental")` and
  `collectgarbage("isrunning")` behave as in PUC; the `T.gcage`/`T.gccolor`
  object ages are not observable (no `T` hooks here); the barrier-driven data
  checks pass because no object is moved between age lists; and the one
  assertion that does look at collector progress (line 122) counts steps as
  above. Everything else in the file is inert on both sides. Measured
  the same on x86_64 and aarch64, `-joff` and `-jon`; repro
  `tests/lib/gc-step-quantum-repro.lua`, in the harness the mode-A row of
  `tests/corpus/puc54/gengc.lua` (its assert at line 122) in
  `tests/known-different.tsv`.

- `IMPL-DEFINED` A compiled loop whose allocations the JIT eliminates does not
  advance the collector. A constructor that never escapes is sunk into the
  trace snapshots and an unused string or table is removed by dead-code
  elimination (stock LuaJIT optimizations), so the compiled loop allocates
  nothing and never reaches a GC step, while PUC allocates every object. A loop
  that allocates only to wait for a finalizer or for a weak-table entry to be
  cleared may therefore not end under the JIT; the interpreter (`-joff`, and
  `-O0`..`-O2`, which do not sink) follows PUC. A trace that read a weak table
  keeps its allocations. The manual does not say when the collector runs.
  `gc.lua`'s GC1/GC2 loops (lines 57-93, `repeat u = {} until finish`) do not
  end under `-jon` on x86_64 and aarch64 (mode B row in
  `tests/known-different.tsv`); `tests/d54/gc_13_dropped_alloc_pace.lua`
  asserts the interpreter. Charging such loops a virtual allocation per pass
  would end them, but costs a vector-add loop with a sunk table 50 vs 156 ms
  (x86_64, `-jon`); that was not taken.
- `PENDING` What counts as a file handle. PUC's io library accepts a
  userdata as a file when its metatable is the current `registry["FILE*"]`
  (liolib.c `tofile`/`io_type`, `luaL_checkudata`/`luaL_testudata`); this
  tree accepts every io handle by its userdata kind (`UDTYPE_IO_FILE`,
  `io_tofilep` and `io_type` in `src/lib_io.c`, and the recorder's guard in
  `recff_io_fp`). Only a program that changes `registry["FILE*"]` or a
  handle's metatable sees it: a handle made while the entry was nil, or
  whose metatable was replaced through `debug.setmetatable`, is still "file"
  for `io.type` and is closed by `io.close` here, where PUC answers nil and
  "FILE* expected, got userdata" (evidence: puc-code liolib.c,
  measured-here on arm64 with the probe of
  `tests/d54/io_05_filehandle_registry.lua`'s shapes). Matching it needs the
  metatable comparison in every io entry point and a guard on the registry
  entry in the traces of the recorded io functions; not attempted yet.

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
  PUC 5.4 removed them, and the Lua-level `getfenv`/`setfenv`, `loadstring`,
  the global `jit`/`bit` tables and the `package.preload` modules (`ffi`,
  `jit.profile`, `jit.util`, `string.buffer`, `table.clear`, `table.new`)
  are additive. A 5.4 program that reads named globals or named modules sees
  PUC behavior; only code that enumerates all globals or all preload modules
  observes them, and every such extra is in the documented set
  (`tests/d54/ext_01_extra_names.lua`).

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
  function expression `a -> b` / `|x| -> x*x` and the `continue` statement
  (a soft keyword: `continue` before `end`, `else`, `until` or `;`). Code that
  probes for the
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
  Runtime `collectgarbage("setpause" / "setstepmul")` overrides either, and
  the `-G`/`LUAJIT_GC` request restores the opt-in policy. The `speed` value is
  a deliberate divergence from stock LuaJIT 2.1's 200/200; it
  buys stock-parity k-nucleotide and a faster binary-trees for more peak RSS.
