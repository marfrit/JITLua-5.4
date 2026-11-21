# JITLua-5.4 1.0.0 — release notes (draft)

JITLua-5.4 is a fork of LuaJIT 2.1 that implements the Lua 5.4.9 language and
C API on top of LuaJIT's JIT compiler. Release archive:
`JITLua-5.4-1.0.0.tar.gz`. This is not an official LuaJIT release and is not
supported by Mike Pall (see [README.md](../README.md)).

## Highlights

- Lua 5.4.9 semantics in the interpreter and in compiled code: 64-bit
  integers next to floats, `//` and the bitwise operators, 5.4 numeric `for`
  rules, `goto`, `<const>` and `<close>`, `coroutine.close`, 5.4 `__eq`
  selection, `__gc` on tables, the 5.4 standard library (`utf8`,
  `string.pack`/`unpack`, `table.move`, and the rest) and the 5.4 `collectgarbage`
  interface. Overview: [LUA54.md](LUA54.md).
- A C API that is source-compatible with PUC Lua 5.4 (5.4 additions such as
  `lua_newuserdatauv`, `lua_toclose`, `lua_arith`, the PUC `luaL_Buffer`
  layout).
- LuaJIT's FFI, `jit.*` and `bit.*` are kept.
- Verification against PUC Lua 5.4.9, identical on Linux arm64 and x86_64:
  `tests/d54` A+B 419 PASS / 0 FAIL / 4 XFAIL, JIT optimization levels 0-3
  888, dump/reload 200, assertion build 222, GC stress 210, ASan/UBSan A+B+R
  619 PASS / 0 FAIL / 4 XFAIL; full corpus (PUC 5.4.9 test suite plus
  `tests/d54`) with `--strict` 696 PASS / 0 FAIL / 14 XFAIL / 3 SKIP /
  0 TIMEOUT. No open row in `tests/known-bad.tsv`.
- Performance: against stock LuaJIT 2.1 the classic benchmarks are within
  10 % on both architectures, except two readings of workloads that run for
  10 ms or less and that a second measurement did not confirm: arm64 nbody
  at 0.731 in the interleaved run of 2026-11-20 (0.982 measured alone) and
  x86_64 fasta at 0.84 in the 2026-11-21 run (1.039 on 2026-11-20; to be
  re-measured). Against PUC Lua 5.4.9 the fork is faster on every classic
  workload on both architectures, except scimark on x86_64, where PUC is
  2.6 % faster (28808.5 ms against 29588.0 ms). Figures and method:
  [perf-report-1.0.0.md](perf-report-1.0.0.md).

## Compatibility statement

- **Language and libraries**: the goal is 100 % source compatibility with
  PUC Lua 5.4.9 wherever it is technically possible. Programs that use only
  Lua 5.4 see PUC's behavior, apart from the differences listed below.
- **C API**: source-compatible, **not binary-compatible**. C modules must be
  rebuilt against JITLua's headers. A module built against PUC's headers that
  calls `luaL_checkversion` (as `luaL_newlib` does) is refused at load with a
  message that asks for a rebuild. A module that never calls it cannot be
  detected, so rebuild every module. Modules built against an earlier
  JITLua-5.4 must be rebuilt too (the `luaL_Buffer` layout changed).
- **Bytecode**: `string.dump` writes a private format (version 0x85). PUC
  Lua cannot load it, and dumps written by earlier JITLua-5.4 versions are
  refused.
- **LuaJIT 2.1 programs**: LuaJIT's extensions stay (FFI, `jit.*`, `bit.*`,
  `getfenv`/`setfenv`, `loadstring`), but Lua 5.1 semantics do not: a program
  written for LuaJIT 2.1 runs with Lua 5.4 rules for numbers, comparisons,
  `for` loops and the standard library. The Lua 5.1 leftovers (`unpack`,
  `gcinfo`, `newproxy`, `module`, `table.getn` and friends,
  `package.loaders`, `package.seeall`) are not in the default build;
  `make CFLAGS=-DLUAJIT_ENABLE_51COMPAT` builds them back. `jit.version` reads
  `JITLua-5.4 (LuaJIT 2.1.<relver>)`; code that tests `^LuaJIT` to detect
  the `ffi` module should use `pcall(require, "ffi")`.
- **Syntax**: the short function `a -> b` and the `continue` statement of
  LuaJIT 3.0 are accepted where PUC rejects them. Identifiers are ASCII only.

## Known differences

Short list; every item has its technical reason in
[DIFFERENCES.md](DIFFERENCES.md), and every fixed one in
[CHANGELOG-VM.md](CHANGELOG-VM.md).

- Private bytecode dump format; a stripped dump keeps no `linedefined`.
- Stack depth, slots per frame (250), constants per function (65536), jump
  distance (32767 instructions), maximum table array size and nesting depth of
  syntax differ from PUC's; the C-call bound counts only calls that pass
  through C.
- One incremental collector. `collectgarbage("generational")` returns the
  right mode strings but there is no separate generational collector; the step
  quantum, the number of collection cycles and `collectgarbage("count")` grain
  differ. The default pause/stepmul are 300/200 (`LUAJIT_GC=memory` or
  `luajit -G memory` selects 100/200).
- A compiled loop whose allocations the JIT eliminates is not charged to the
  collector, so a loop that allocates only to wait for a finalizer may not end
  under the JIT. Dead stack slots of a compiled loop stay alive until the trace
  exits.
- LuaJIT interns every string, so `%p` identity after concatenation differs.
- The border of a runtime-built sparse table may differ from PUC's.
- The continuation API (`lua_callk`, `lua_pcallk`, `lua_yieldk`) exists but
  never calls the continuation.
- Inherited syntax `->` and `continue`, FFI literal suffixes.

## Supported platforms

- Linux x86_64 with GC64.
- Linux arm64.

The other LuaJIT backends (x86, arm, ppc, mips, and x86_64 without GC64) are
not ported to the 5.4 changes and do not build; a non-GC64 x86_64 build stops
with an `#error` that names the missing pieces. Windows and macOS are
untested.

## Building

A C compiler and `make` are required: `make -j"$(nproc)"`. Put your own
preprocessor defines in `CFLAGS`, never in `XCFLAGS` (a command-line
`XCFLAGS=` replaces the dual-number define and the build stops). Build,
GC policy, test and CI instructions are in [README.md](../README.md); the test
harness is described in `tests/README.md`.

## After 1.0.0

Fuzzing is not a release gate for 1.0.0; the coverage-guided campaign
continues after the release and feeds 1.0.x (decision of 2026-11-21 in
[MISSION.md](../MISSION.md)). Other open items are in [plan.md](plan.md).

## Acknowledgements

- LuaJIT by Mike Pall (MIT license): the code base, the JIT compiler, the FFI
  and the `jit.*` and `bit.*` modules.
- Lua by PUC-Rio (MIT license): the language, the reference implementation
  and the test suite the differential corpus is derived from.
- Computer Language Benchmarks Game (BSD-3-Clause): the k-nucleotide benchmark
  source.
- Development: Markus Fritsche with Claude (Anthropic), a locally run
  DeepSeek model, Qwen4-Max-Preview and a local Qwen3.6-Coder, as stated in
  the README.

Naming these projects states where the code comes from. It does not imply
that their authors endorse or support this fork.
