# Lua 5.4 in JITLua-5.4

This is the overview of what JITLua-5.4 1.0.0 implements of Lua 5.4.9, what
stays specific to LuaJIT, and what still differs. It is a reading guide; the
record behind it is [DIFFERENCES.md](DIFFERENCES.md) (every remaining
difference, with a class and a reason) and [CHANGELOG-VM.md](CHANGELOG-VM.md)
(every fixed one, with technical notes). The measured gate counts are in
[../README.md](../README.md).

The goal is fixed in [../MISSION.md](../MISSION.md): source compatibility with
PUC Lua 5.4.9 wherever it is technically possible. Platforms are Linux x86_64
(GC64) and Linux arm64. Other LuaJIT backends are not maintained and do not
build with the 5.4 changes (see [Platforms](#platforms)).

## What is implemented

Reference for every statement below is PUC Lua 5.4.9. The comparison is made
by the differential harness (`tests/harness.sh`): PUC 5.4.9 against this
fork with the JIT off (mode A), the JIT on against off at optimization levels
0 to 3 (mode B) and a dump/reload round-trip (mode R). The PUC 5.4.9 test
suite runs as part of the corpus; three of its files (`all`, `api`, `code`)
exist only for the suite's internal test library `T` and do not run
(README, [tests/t-guarded.tsv](../tests/t-guarded.tsv)).

### Language

- Integers and floats are two subtypes of number. Integers are signed 64 bit
  and wrap on overflow; `math.type`, `math.tointeger` and `math.ult` exist.
  Integer values outside the int32 range are held either inline (47 bit, GC64)
  or in an interned box; the value model is described in
  [adr-001b-boxed-i64.md](adr-001b-boxed-i64.md). Compiled code and the
  interpreter agree on the subtype of every result (mode B).
- Arithmetic follows 5.4: `//` is integer floor division for integers,
  `%` takes the sign of the divisor for integers, `^` and `/` give floats,
  string operands are coerced as in 5.4 (a numeric string that denotes an
  integer stays an integer). String arithmetic is part of the VM's arithmetic
  fallback; the string metatable has no `__add` entries (DIFFERENCES.md).
- Bitwise operators `& | ~ << >>` and unary `~` work on 64-bit integers, with
  5.4's rule for floats with an exact integer value and the `__band` ...
  `__bnot` metamethods.
- Numeric `for` loops follow PUC's `forprep`/`forlimit`: the loop kind is
  decided by the initial value and the step, the limit is converted with
  floor/ceil or clipped, the iteration count of an integer loop cannot
  overflow, and the error texts are PUC's. The design is in
  [notes/for-loop-54.md](notes/for-loop-54.md).
- `goto` and labels with 5.4's scoping rules; `return` ends a block.
- `<const>` and `<close>` local attributes, `__close` metamethods, including
  the error path and `coroutine.close`. A `__close` handler on the error path
  of a `pcall`/`xpcall` called from Lua may yield, as in PUC.
- String to number conversion and numerals follow the 5.4 rules. The identifier alphabet is ASCII only.
- Coroutines include `coroutine.close`, with 5.4 semantics and error
  messages.
- Metamethods follow 5.4: `__eq` uses the first operand's handler and then
  the second's, passing operands in source order; `__len` results that a caller needs as an integer are checked
  ("object length is not an integer"); `__tostring` must return a string; `__name`
  is used in messages; `__gc` on tables with 5.4's marking, order and
  resurrection rules; `__close`; `__idiv`, `__band`, ... for the new operators.
- Environments: `_ENV` is an ordinary upvalue and may hold any value.

### Standard library

- `table`: `move`, `pack`, `unpack` (with `i`, `j`), `concat`, `insert`,
  `remove`, `sort`. `table.move`, `unpack`, `concat` and the other functions
  that read or write elements honour `__index`, `__newindex` and `__len`, as
  in 5.4. `table.concat` calls `__len` first, as `ltablib.c` does. The
  recorder guards the metatable, so a loop compiled for plain tables does not
  keep a raw path after a metatable with `__len` is attached.
- `string`: 5.4 `format` rules (`%d` accepts floats only with an exact integer
  value, `%a`, `%q` for numbers, error order as in `lstrlib.c`), `pack`,
  `unpack`, `packsize` and `rep` with a separator.
- `utf8`: `char`, `charpattern`, `codes`, `codepoint`, `len`, `offset`.
- `math`: the 5.4 integer/float split, `math.random` and `math.randomseed` as
  in 5.4, `min`/`max` that keep the winner's subtype.
- `os` and `io`: 5.4 `os.date`/`os.time` field rules, `io.read` number
  formats, `io.lines`, `seek`, `<close>` on file handles.
- `debug`: `upvalueid`, `setcstacklimit`, `getinfo` with 5.4
  fields (including `istailcall`), hook events with 5.4 call/return rules.
- `package`: `package.searchers` with the two-result protocol and
  `require(name, data)`.
- `collectgarbage`: the 5.4 option set, `"incremental"` and `"generational"`
  mode strings and return values, `"step"` with PUC's debt rule, `pause`
  and `stepmul` stored as PUC stores them. The collector itself is LuaJIT's
  single incremental collector; see [Remaining differences](#remaining-differences).
- Warnings (`warn`, `lua_setwarnf`).

### C API

The C API is **source-compatible** with PUC Lua 5.4: a C module that builds
against PUC's headers builds against JITLua's headers. It is **not
binary-compatible**: modules must be rebuilt against JITLua's headers. The
reasons (DIFFERENCES.md, "source-compatible" row):

- the pseudo-indices keep LuaJIT's values (`LUA_REGISTRYINDEX` is -10000 and
  `lua_upvalueindex(i)` is -10002-i);
- `luaL_Buffer` has the PUC 5.4 layout but `LUAL_BUFFERSIZE` is larger;
- `lua_getextraspace` is a function and the area sits after `struct
  lua_State`, not before it;
- `luaL_checkversion` passes a fork-specific ABI stamp, so a module built
  against PUC's headers that calls it (as `luaL_newlib` does) is refused at
  load with a message that asks for a rebuild.

Implemented 5.4 additions include `lua_newuserdatauv`, `lua_get/setiuservalue`,
`lua_arith`, `lua_toclose`/`lua_closeslot`, `lua_closethread`/`lua_resetthread`,
`lua_resume` with the 5.4 signature, `lua_warning`, `lua_setwarnf`,
`lua_stringtonumber`, `luaL_len`, `luaL_addgsub`, `luaL_tolstring`,
`luaL_requiref`, `luaL_pushfail`, and the PUC 5.4 module-facing macros of
`luaconf.h`. The full header comparison is in
[notes/capi-header-compat.md](notes/capi-header-compat.md).

The continuation API (`lua_callk`, `lua_pcallk`, `lua_yieldk`) exists, but the
continuation function `k` is never called: LuaJIT has no C continuation
frames. `lua_yieldk` with a non-NULL `k` raises "attempt to yield across a
C-call boundary". See DIFFERENCES.md for what that means for `lua_toclose`
in a yielding C function.

## What stays LuaJIT-specific

These are LuaJIT 2.1 features kept on purpose (MISSION non-goals; DIFFERENCES.md
"Kept LuaJIT extensions"):

- **FFI** (`require("ffi")`, cdata, `LL`/`ULL`/`i` literal suffixes) and the
  64-bit cdata types. Intended integer semantics are in
  [ffi-int-semantics.md](ffi-int-semantics.md).
- **`jit.*`**: `jit.on/off/flush/status`, `jit.opt`, `jit.util`,
  `jit.profile`, the `-j` and `-O` command-line options and the dump and
  profiler modules. `jit.version` and `luajit -v` read
  `JITLua-5.4 (LuaJIT 2.1.<relver>)`.
- **`bit.*`**: kept, with a hybrid rule for native 5.4 integers (calls whose
  arguments are all numbers wrap modulo 2^32 as in stock LuaJIT; a call with a
  64-bit cdata operand converts native integers exactly). Exact 64-bit work
  uses the 5.4 operators.
- **Bytecode**: `string.dump` writes JITLua-5.4's private format (version
  0x85). PUC 5.4.9 cannot load it and this fork cannot load PUC's; an older
  JITLua dump is refused with the usual "cannot load incompatible bytecode".
  The `-b` option and `jit.bcsave` are LuaJIT's. A stripped dump keeps no
  `linedefined`.
- **Library extras**: `getfenv`, `setfenv`, `loadstring`, `table.new`,
  `table.clear`, `string.buffer`. `loadstring` is in every build because
  Penlight depends on it.
- **Syntax inherited from LuaJIT 3.0**: the short function expression
  `a -> b` and the `continue` statement (a soft keyword). PUC 5.4.9 rejects
  both; code that probes for the rejection sees the difference.
- **GC policy mode** (`LUAJIT_GC=speed|memory`, `luajit -G`): the default is
  pause 300 / stepmul 200, not PUC's 200/100.

Removed from the default build: the Lua 5.1 leftovers `unpack`, `gcinfo`,
`newproxy`, `module`, `table.getn/foreach/foreachi/maxn`, `package.loaders`
and `package.seeall`. `make CFLAGS=-DLUAJIT_ENABLE_51COMPAT` builds them back.

A 5.4 program that reads named globals or named modules sees PUC behavior.
Only code that enumerates all globals or all `package.preload` modules
observes the extras, and every extra is in the documented allowlist
(`tests/d54/ext_01_extra_names.lua`).

## Remaining differences

DIFFERENCES.md carries one row per difference; every row has a class
(`FORK`, `IMPL-DEFINED`, `PENDING`, `EXTENSION`, `REMOVED`) and every XFAIL in
[tests/known-different.tsv](../tests/known-different.tsv) maps to one of them.
`tests/known-bad.tsv` lists no open defect. The classes of difference that
remain:

| Class | What differs | Where |
|---|---|---|
| Bytecode format | Private dump format; stripped dumps lose `linedefined`. | DIFFERENCES.md, "Against PUC Lua 5.4.9", `string.dump` rows |
| Limits | Stack depth (`LJ_STACK_MAX`), at most 250 slots per frame, 65536 constants per function, jumps of at most 32767 instructions, array size at the stop of `heavy.lua`, how deep syntax may nest, and how many values a C function can push. | "Language and VM": stack overflow, registers, constants, jump distance, nesting rows |
| C-call bound | The "C stack overflow" bound at 200 counts the calls that pass through C; metamethods and `__close` handlers called by the VM are not C calls here. | "Language and VM", first row |
| Garbage collector | One incremental collector; the generational mode is a mode flag. The basic step quantum and the number of cycles a program triggers differ; `collectgarbage("count")` reports LuaJIT's allocation grain; default pause 300 / stepmul 200. | GC mode and basic-step, pause/stepmul, cycle-count and `count` rows |
| GC and the JIT | A compiled loop whose allocations the JIT eliminates is not charged to the collector, so a loop that allocates only to wait for a finalizer may not end under the JIT. A compiled loop also keeps dead stack slots alive until the trace exits. | "A compiled loop whose allocations the JIT eliminates" |
| Strings | LuaJIT interns every string, so `%p` and `lua_topointer` identity after concatenation differs. | `FORK` string interning row |
| Tables | The border of runtime-built sparse tables may differ (any border is legal). | `IMPL-DEFINED` border row |
| `for` state | The hidden `(for state)` slots hold the index, converted limit and step; writing them with `debug.setlocal` to another kind of value cannot reproduce PUC's reinterpretation of raw bits. | `FORK` and `IMPL-DEFINED` for-state rows |
| C API | Not binary-compatible; no C continuation frames; `lua_toclose` in a yielding C function closes at the yield. | C API `FORK` rows |
| Syntax | Inherited `->` short functions and `continue`; FFI literal suffixes; ASCII-only identifiers. | "Against stock LuaJIT 2.1" |
| Platforms | Backends other than x86_64 GC64 and arm64 do not build. | DIFFERENCES.md, "Platforms" paragraph |

Compared with stock LuaJIT 2.1, the added surface (operators, bytecodes,
libraries, C API) and the removed Lua 5.1 names are listed in DIFFERENCES.md
under "Against stock LuaJIT 2.1".

## Platforms

All VM and JIT changes target x86_64 (GC64) and arm64 on Linux. The other
LuaJIT backends (x86, arm, ppc, mips and non-GC64 builds) are not maintained.
For x86_64 without GC64, `src/lj_arch.h` stops the build with an `#error`
that names the missing pieces; the VM for 32-bit GC references has no handler
for `BC_IDIV`, `BC_KI64`, `BC_TBC` or `BC_TBCCLO`. The object layout of that
configuration is still checked by `make layout-check`. Windows and macOS are
untested.

## Where to look next

- Measured state and build notes: [../README.md](../README.md)
- Every remaining difference: [DIFFERENCES.md](DIFFERENCES.md)
- Every fixed divergence: [CHANGELOG-VM.md](CHANGELOG-VM.md)
- Performance: [perf-report-1.0.0.md](perf-report-1.0.0.md)
- Open work after 1.0.0: [plan.md](plan.md)
