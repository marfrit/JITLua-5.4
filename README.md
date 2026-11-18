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
  edge-case corpus: A+B **144 PASS / 0 FAIL / 5 XFAIL**, JIT optimization
  levels 0–3 **316**, R (dump/reload round-trip) **76**; the ASan/UBSan run
  of A+B+R is **220 PASS / 0 FAIL / 5 XFAIL**; C API checks **204 + 14**.
- Full corpus (PUC 5.4.9 test suite plus `tests/d54`) with `--strict`, the
  exact command of the public CI: **276 PASS / 0 FAIL / 9 XFAIL / 12 SKIP /
  0 TIMEOUT**. Every XFAIL is a known-bad entry with its reason in
  `tests/known-bad.tsv`.
- The remaining known gaps and deliberate divergences are recorded in
  [docs/DIFFERENCES.md](docs/DIFFERENCES.md) and
  [tests/known-bad.tsv](tests/known-bad.tsv). Open items include arbitrary
  `_ENV` and the pcall/`__call` VM work in the `calls.lua` corpus, tail-call
  error names, `debug.getinfo(...).istailcall` without a hook, a private dump
  format, and implementation-defined table/GC edges.
- Open performance items: `heavy.lua` requires a box above 8 GiB; classic
  benchmark runs show remaining gaps in deltablue, x64 spectral-norm and x64
  k-nucleotide
  ([docs/perf-regression-2026-11-17.md](docs/perf-regression-2026-11-17.md)).
- **Not yet covered:** arbitrary `_ENV` values, `lua_getextraspace`, the
  no-op `lua_setcstacklimit`, and the remaining pcall/`__call` VM work. See
  the two files above for the exact list.

## Build

Requires a C compiler and `make`:

```sh
make -j"$(nproc)"
```

The build enables dual-number mode with `XCFLAGS += -DLUAJIT_NUMMODE=2` in
`src/Makefile` (line 117). A command-line `XCFLAGS=` **replaces** that variable,
so the define disappears and `src/lj_arch.h` stops the build with a `#error`.
Put your own preprocessor defines in **`CFLAGS`**, never in `XCFLAGS`.

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
