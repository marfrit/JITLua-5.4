<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/jitlua-dark.svg">
    <img src="docs/logo/jitlua-light.svg" alt="JITLua-5.4 logo: a crescent moon with three gears" width="440">
  </picture>
</p>

# JITLua-5.4

A fork of **LuaJIT 2.1** that brings the **Lua 5.4 language and C API** to
LuaJIT's JIT compiler.

This is **not** an official LuaJIT release and is **not supported by Mike
Pall**. It is an independent port maintained by Markus Fritsche. The original
LuaJIT 2.1 README is kept as [README.LuaJIT](README.LuaJIT).

## Status

Status as measured, not a compatibility claim:

- Differential gates against PUC Lua 5.4.9 pass on the tested platforms.
  Measured on Linux arm64 and x86_64, identical on both, on the `tests/d54`
  edge-case corpus: A+B **220 PASS / 0 FAIL / 4 XFAIL**, JIT optimization
  levels 0–3 **488**, R (dump/reload round-trip) **119**; the ASan/UBSan run
  of A+B+R is **339 PASS / 0 FAIL / 4 XFAIL**; C API checks **258 + 92 + 18**
  plus the `udfinal` probe, which prints the same counters as the PUC binary.
- The C API is **source-compatible** with PUC Lua 5.4, **not
  binary-compatible**: C modules must be rebuilt against JITLua's headers.
  A module built against PUC's headers that calls `luaL_checkversion` (as
  `luaL_newlib` does) is rejected at load.
- Full corpus (PUC 5.4.9 test suite plus `tests/d54`) with `--strict`, the
  exact command of the public CI: **392 PASS / 0 FAIL / 8 XFAIL / 12 SKIP /
  0 TIMEOUT**. Every XFAIL has its reason in one of two lists:
  [tests/known-bad.tsv](tests/known-bad.tsv) for real defects, and
  [tests/known-different.tsv](tests/known-different.tsv) for deliberate or
  implementation-defined differences.
- Known defects (known-bad.tsv): none open.
- Known differences (known-different.tsv, all described in
  [docs/DIFFERENCES.md](docs/DIFFERENCES.md)): a private bytecode dump format
  (including the `calls.lua` binary-chunk section), the border of runtime-built
  sparse tables, LuaJIT's maximum table array size (`heavy.lua`), the
  inherited LuaJIT 3.0 short-function syntax `->`, and two points of `db.lua`
  (a dead stack slot that keeps an object from being finalized; no
  `linedefined` in a stripped dump).
- Fixed divergences (former known bugs) with their technical notes are in
  [docs/CHANGELOG-VM.md](docs/CHANGELOG-VM.md).

## Build

Requires a C compiler and `make`:

```sh
make -j"$(nproc)"
```

The build enables dual-number mode with `XCFLAGS += -DLUAJIT_NUMMODE=2` in
`src/Makefile` (line 117). A command-line `XCFLAGS=` **replaces** that variable,
so the define disappears and `src/lj_arch.h` stops the build with a `#error`.
Put your own preprocessor defines in **`CFLAGS`**, never in `XCFLAGS`.

## GC policy mode

The default collector policy is **time-first**: pause 300 %, stepmul 200 %. It
was raised from 200 % after a measurement on both arches
(`docs/notes/knuc-phase-align-2026-11.md`): k-nucleotide reaches stock parity
(0.89 → 1.00 on x86_64, 0.853 → 0.979 on arm64) and binary-trees gets faster
(0.97 → 1.07, 1.00 → 1.04), with lpeg and lua-cjson unchanged. The price is
peak RSS: binary-trees +31 %, lpeg +17 %, lua-cjson flat.

An opt-in **memory** mode trades time for RSS: it collects at 100 % of live
memory (`setpause=100`) with the same step speed. Per `docs/gc-newgen-plan.md`
(Stage 0(a), the `setpause=100` row of the measurement table) that closes about
76 % of the binary-trees peak-RSS gap to PUC 5.4.9, at the cost of more
collector work. Select it either way:

```sh
LUAJIT_GC=memory ./src/luajit -jon script.lua
./src/luajit -G memory -jon script.lua
```

`LUAJIT_GC` is read in `luaL_newstate()` (`src/lib_aux.c`), so every embedder
that creates its states with it sees the variable (`lua_newstate()` does not
read it). `-G` overrides the environment and `-E` ignores it; unknown values
are ignored silently. A runtime `collectgarbage("setpause", n)` or
`"setstepmul"` overrides either, and `collectgarbage("incremental"/
"generational")` is unaffected. `tests/gcmode.sh` checks the read-back values
for the default, both environment values, the CLI option and the precedence
rules.

## Tests

The differential harness compares this fork against PUC Lua 5.4.9 and across
JIT on/off and dump/reload:

```sh
tests/ref/fetch-ref.sh          # fetch/build the reference and fixtures
tests/harness.sh --mode all --timeout 120
```

`luaL_Buffer` follows the PUC 5.4 layout and `luaL_prepbuffer` is a macro over
`luaL_prepbuffsize`, so C modules built against an earlier JITLua-5.4 must be
recompiled (the auxlib ABI changed).

The local CI equivalent, including C API and fuzz runs:

```sh
tests/ci-box.sh
```

`make layout-check` compiles the GC object headers for x86_64 in both the GC64
and the non-GC64 reference layout (no VM, no JIT, a fraction of a second). It
is also a stage of `tests/ci-box.sh`.

The box scripts are thin wrappers around private remote build hosts: they copy
the working tree, run the command there and return stdout; the wrappers
themselves are not part of this repository.

Harness modes: **A** (reference vs this fork, JIT off), **B** (JIT on vs off),
**R** (direct vs `string.dump`→`load` round-trip). `--strict` treats an
unexpected pass of a known-bad entry as a failure.

ASan/UBSan are part of the public CI gate (the `linux-x64-sanitizers` job);
the local run of `tests/ci-local.sh --sanitizers-only` is green on both
architectures. Locally, `tests/ci-local.sh --sanitizers-only` builds the
instrumented VM and runs both the differential harness and the C API tests.

## Platforms

Tested on **Linux/arm64** and **Linux/x86_64** only. Windows and macOS are
untested; Windows builds are not part of CI.

## Credits and licenses

- **LuaJIT** by Mike Pall, MIT license. This fork keeps the LuaJIT code base and
  its extensions (`jit.*`, `bit.*`, FFI, bytecode dump).
- **Lua 5.4** by PUC-Rio, MIT license. The differential test corpus is derived
  from the [lua/lua](https://github.com/lua/lua) repository.
- **Computer Language Benchmarks Game** (BSD-3-Clause):
  `tests/lib/perf-knuc.lua` is derived from its k-nucleotide benchmark.
- Development: Markus Fritsche with Claude (Anthropic: Fable and Opus),
  meseeks (a private DeepSeek-V4.1-Flash quant, run locally),
  Qwen4-Max-Preview, and a local Qwen3.6-Coder.

See [COPYRIGHT](COPYRIGHT) and [README.LuaJIT](README.LuaJIT) for the original
license and documentation pointers.
