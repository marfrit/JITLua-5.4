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
  decision, Markus 2026-11-16).
- `FORK` `string.dump` uses JITLua-5.4's private format; PUC 5.4.9 cannot load
  it, and mode R checks our own dump/reload round-trip.
- `PENDING` Arbitrary `_ENV` values: LuaJIT stores only a table as a function
  environment; `load("return _ENV", nil, nil, 123)()` does not return 123
  (calls.lua A stops at line 359; VM/C-API work, branch `wip-calls-vm`).
- `PENDING` pcall/xpcall C-call nesting bound and `__call` chain argument
  prepending (calls.lua A/B; VM work on `wip-calls-vm`; handler-reentry bound is
  already on main).
- `IMPL-DEFINED` Sparse-table border for runtime-built tables may differ: 5.4
  allows any border; LuaJIT's array-growth policy differs from PUC's alimit hint
  (`tbl_03_border_divergence`).
- `IMPL-DEFINED` `__gc` finalization runs only for userdata, not tables (PUC 5.4
  finalizes tables; `gc_01_tbc_gc`).
- `EXTENSION` `table.create` is a LuaJIT extension (nil in PUC 5.4).
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
- `PENDING` `lua_setcstacklimit` is a no-op returning `LUAI_MAXCCALLS` (200);
  PUC sets a new C-stack limit and returns the previous one.
- `FORK` C functions that marked a slot with `lua_toclose` and then yield close
  that slot at yield time, not when the frame "returns" after the resume: with
  no C continuation frame there is no later point to run `__close`. PUC keeps
  them pending across the resume. Observable in the order of `__close` calls
  relative to `coroutine.resume` (`tests/capi` `test_toclose`). An error (or
  yield) inside such a `__close` is raised in the coroutine at the yield, not
  after the resume; a yielding `__close` fails with "attempt to yield across a
  C-call boundary" instead of PUC's yieldable continuation.
- `EXTENSION` `luaL_Buffer` uses the PUC 5.4 layout and `luaL_prepbuffer` is a
  macro over `luaL_prepbuffsize`. This changes the auxlib ABI: C modules
  compiled against an older JITLua-5.4 auxlib must be recompiled.
- `FORK` The 5.4 C continuation API (`lua_callk`, `lua_pcallk`, `lua_yieldk`)
  is present, but LuaJIT has no C-level continuation frames: `k` is never
  called and `ctx` is ignored. `lua_pcallk` never returns `LUA_YIELD`;
  `lua_yieldk` with a non-NULL `k` raises "attempt to yield across a C-call
  boundary" instead of silently skipping the continuation. Plain
  `lua_yield` from a C function still works, including a tail yield
  (`tests/capi` `test_continuations`).
- `PENDING` The number metatable does not apply to integers outside the inline
  47-bit range (boxed int64): after `debug.setmetatable(0, {__index = math})`,
  `(1):floor()` works but `((1 << 50) + 3):floor()` raises, and
  `getmetatable` of such an integer returns nil (PUC returns the number
  metatable). Interpreter and JIT agree; found in the release review.
- `PENDING` `lua_getextraspace`: there is no reserved pointer-sized area before
  `lua_State`. Adding one would need a layout change in `GG_State` and in every
  per-thread allocation, moving the GC object/interior pointer and the assembler
  offsets; not done. Modules using it need a portable side area instead.

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
- `PENDING` `closure.lua` mode B on arm64: JIT-on exceeds 600 s while JIT-off
  passes (PERF triage).
- `IMPL-DEFINED` `heavy.lua` runs under a 4 GiB `RLIMIT_AS` cap in the
  `--include-heavy` stage; both sides then end in an allowed resource error
  (Lua 5.4 manual 3.4.7), but the reports differ: PUC stops with "not enough
  memory" at `#a=134217728` (peak ~2.0 GiB RSS) while LuaJIT stops with
  `heavy.lua:154: table overflow` at `#a=201326592` (peak ~3.3 GiB), and the
  `collectgarbage` byte counts differ in every mode. Excluded from the default
  corpus; see `tests/known-bad.tsv`.
- `PENDING` Classic benchmarks slower than stock 2.1 (>10%): deltablue both
  arches (missing-metamethod trace loss), spectral-norm x64 (integer-loop
  guards/CONVs), k-nucleotide x64 (`__index`/string-key path); see
  `docs/perf-regression-2026-11-17.md` and `docs/bench-classic-2026-11-17.md`.


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
- `EXTENSION` `utf8.*`, `string.pack/unpack`, `table.rawlen`, `math.type/
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
  PUC.
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
