# Differences — LuaJIT-5.4 vs PUC Lua 5.4.9 and stock LuaJIT 2.1

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
- `FORK` `string.dump` uses LuaJIT-5.4's private format; PUC 5.4.9 cannot load
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
- `PENDING` Userdata arrays with more than one user value and non-GC user values
  are not supported (GC layout / GCRef-slot limitation; C API notes).

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
- `PENDING` `heavy.lua` needs near 8 GiB in the PUC reference and OOM-kills an
  8 GiB box; excluded from the default corpus, explicit `--include-heavy` stage.
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

### Added 5.4 standard library / C API
- `EXTENSION` `utf8.*`, `string.pack/unpack`, `table.rawlen`, `math.type/
  tointeger/ult`, `package.searchers` two-result protocol and `require(name,data)`,
  `io` 5.4 read/seek/lines rules, `os.date/time` 5.4 field rules.
- `EXTENSION` 5.4 C API: `lua_newuserdatauv`, `lua_get/setiuservalue`,
  `lua_warning`/`warn`, `lua_setwarnf`, `lua_resume` 5.4 signature, integer
  checks/return types, `luaL_addgsub/buffsub/pushfail`, `luaL_tolstring/
  requiref/typeerror`.
- `EXTENSION` `lua_getfenv`/`setfenv` remain present as LuaJIT extensions;
  PUC 5.4 removed them.

### Kept LuaJIT extensions
- `EXTENSION` `jit.*`, `bit.*`, `ffi`/cdata, `bcsave`, `-j`/`-O`/`-b` options.
- `EXTENSION` FFI int64/uint64 cdata and bit operations on cdata; intended
  semantics are in `docs/ffi-int-semantics.md` (tests `ffi_int_*`, modes B/R).
- `EXTENSION` LuaJIT's pattern-matching implementation and its string-buffer
  optimizations remain; 5.4 pattern behaviors are covered by `str_03_patterns`.
- `EXTENSION` `string.dump` bytecode format and `-b`/`bcsave` are
  LuaJIT-specific; `dump_03_version` records the fork format.
