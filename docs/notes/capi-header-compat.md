# Public-header compatibility with PUC Lua 5.4.9

Scope: the C modules a Lua 5.4 host can load. PUC 5.4.9's `lua.h`,
`luaconf.h`, `lualib.h` and `lauxlib.h` were compared with JITLua-5.4's, and
the differences were closed where a module may rely on them. Both public and
module-facing macros were listed with `gcc -dM -E` over the four headers, then
the real third-party module that exposed the gap (luasystem 0.4.4) was built
against the JITLua headers.

Method:

```sh
gcc -dM -E -I<lua-src> - <<<'#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"' | sort
```

The JITLua tree already pulled `<limits.h>` and `<stddef.h>` in through
`luaconf.h` (the round-1 luasystem failure), so `INT_MAX`, `LONG_MAX` and
`SIZE_MAX` were available transitively; the missing items were the helper
macros and constants below.

## Added (previously missing)

| Header | Added |
|---|---|
| `luaconf.h` | `lua_numbertointeger`, `lua_str2number`, `lua_strx2number`, `lua_pointer2str`, `lua_number2strx`, `lua_getlocaledecpoint`, `LUAI_MAXCCALLS` (200), `luai_likely`/`luai_unlikely` (`l_likely`/`l_unlikely` under `LUA_CORE`/`LUA_LIB`), `LUAMOD_API` |
| `lua.h` | `LUA_NUMTYPES` (9), `LUA_NUMTAGS` |
| `lauxlib.h` | `LUA_GNAME`, `LUA_PRELOAD_TABLE`, `LUAL_NUMSIZES`; `luaL_checkversion` passes the fork ABI stamp (`LUAL_NUMABI`) |

Two existing macros were corrected rather than added:

- `lua_integer2str` used `sprintf()` and passed its `sz` argument as the
  format string. It now uses `snprintf()` like PUC's `l_sprintf`.
- `lua_number2str` had LuaJIT's 2-argument `(s, n)` form. It now takes PUC
  5.4's `(s, sz, n)` form; only `src/host/minilua.c` used the old form and it
  defines its own macro.

## Already present, so unchanged

`LUA_MAXINTEGER`, `LUA_MININTEGER`, `LUA_MAXUNSIGNED`, `LUAI_MAXSTACK`,
`LUA_IDSIZE`, `LUAL_BUFFERSIZE`, `LUA_KCONTEXT`, `LUA_EXTRASPACE` and
`lua_getextraspace` (function, not macro), `luaL_argcheck`,
`luaL_argexpected`, `luaL_newlib`, `lua_pushliteral`, `luaL_pushfail`,
`luaL_addchar/addsize/buffsub`, and the `<limits.h>` / `<stddef.h>` includes.

## Intentionally different (not bugs)

- `LUAI_MAXSTACK` is 65500 in JITLua (LuaJIT's real stack limit) and 1000000
  in PUC; it is the limit of *this* implementation, not a moved constant.
- `LUAL_BUFFERSIZE` is `(BUFSIZ > 16384 ? 8192 : BUFSIZ)` (the auxlib ABI
  buffer size) vs PUC's `16*sizeof(void*)*sizeof(lua_Number)`.
- `LUA_KCONTEXT` is `intptr_t`; PUC's effective value in C99 is also
  `intptr_t` (`ptrdiff_t` is its C89 fallback).
- `lua_call`, `lua_pcall`, `lua_getextraspace` etc. are real functions in
  JITLua where PUC uses macros over the `*k` variants. Source-compatible; the
  symbols are exported.
- `LUA_REGISTRYINDEX` and the LuaJIT pseudo-indices (`LUA_GLOBALSINDEX`,
  `LUA_ENVIRONINDEX`) keep LuaJIT's values; `LUA_RIDX_MAINTHREAD`/`GLOBALS`
  are not exported. Modules should use `lua_pushglobaltable`, which exists.
- `lua_writestring*` and PUC's internal `l_*` helpers (`l_sprintf`,
  `l_mathop`, `l_floor`) are standalone-interpreter internals and were not
  added.
- `lua_assert` stays under `LUA_USE_ASSERT`; PUC's is in its internal
  `llimits.h`. `luai_apicheck` is available under `LUA_USE_APICHECK` in both.

## `luaL_checkversion_`

PUC compares the numeric-type size stamp and the version and raises a Lua
error. JITLua's version lived in `lj_api.c`, asserted `sz == LUAL_BUFFERSIZE`
(not `LUAL_NUMSIZES`), and the assert compiled out in release builds, so a
module built against PUC 5.4.9 headers could pass a mismatched stamp silently.
It moved to `lib_aux.c`, compares `sz` and the version, and raises PUC's
errors:

```
core and library have incompatible numeric types
version mismatch: app. needs %f, Lua core provides %f
```

Source compatibility only: the C API is not a binary drop-in for PUC 5.4 in a
running installation, and C modules must be rebuilt against JITLua's headers.
`LUAL_NUMSIZES` deliberately keeps PUC's value so source code that uses it
still compiles and behaves, but `luaL_checkversion()` now passes
`LUAL_NUMABI` = `LUAL_NUMSIZES + LUAL_ABISTAMP`, a fork-specific stamp
(`LUAL_ABISTAMP` = `0x4a49544c`, "JITL"). `luaL_checkversion_` recognises
PUC's own numeric stamp (`sizeof(lua_Integer)*16 + sizeof(lua_Number)` in
this build's types) and rejects it with a hint:

```
core and library have incompatible numeric types: module built for a
  different Lua ABI; rebuild it against JITLua headers
```

A module whose numeric types really differ still gets PUC's plain mismatch
error; the ABI hint is reserved for a module that passed PUC's numeric stamp.
This catches every module that calls `luaL_checkversion` — including through
`luaL_newlib`, which most modules use. A raw `luaopen_*` that never calls it
cannot be caught: it loads and may read the wrong `LUA_REGISTRYINDEX`,
`lua_upvalueindex`, `luaL_Buffer` or extraspace. Rebuild every module; the
check is a guard, not a proof.

A module compiled against JITLua headers from before this change passes
`LUAL_NUMSIZES` (PUC's value) as its stamp and is rejected the same way:
rebuild it.

The differences that make a rebuild necessary: `LUA_REGISTRYINDEX` (-10000)
and `lua_upvalueindex(i)` (-10002-i) keep LuaJIT's pseudo-indices where PUC
5.4 uses -LUAI_MAXSTACK-1000 and `LUA_REGISTRYINDEX-(i)`; `luaL_Buffer` is
larger (`LUAL_BUFFERSIZE` is 8192/BUFSIZ, PUC's is
`16*sizeof(void*)*sizeof(lua_Number)`); `lua_getextraspace` is a function and
its area sits after `struct lua_State`.

## `lua_setcstacklimit`

PUC 5.4.9 keeps it as a deprecated no-op that returns `LUAI_MAXCCALLS` (200);
JITLua already did. The constant now lives in `luaconf.h` and
`tests/capi` checks the contract (`lua_setcstacklimit(L, 0|5|1000000) == 200`).

## Tests

- `tests/capi/abi_probe.c` is built twice from one source: against PUC 5.4.9's
  headers it must be rejected when JITLua loads it (the driver
  `abi_probe_reject.lua` checks the ABI hint), and against JITLua's headers it
  must load and use `lua_upvalueindex` and `LUA_REGISTRYINDEX`
  (`abi_probe.lua`).
- `tests/capi/headers_probe.c` is compiled as a loadable module and does
  **not** include `<limits.h>`; it fails with `#error` if a macro is missing.
  `tests/capi/headers_probe.lua` checks the read-back values under `-joff`
  and `-jon`.
- `tests/capi/luasystem.sh` builds luasystem 0.4.4 from the vendored tarball
  `tests/capi/dist/luasystem-0.4.4.tar.gz`
  (sha256 `d20786035f5d5a9ab3555813a3e495516efeba32909007ca0155a73d7695ee4a`)
  against the public headers and loads `system.core` under `-joff` and `-jon`.
  The tarball is the unmodified upstream release (75 kB, MIT licence,
  Copyright (c) 2016-2024 Oscar Lim; the licence text is `LICENSE.md` inside
  it). It is test input only and is not linked into or installed with JITLua.
- `headers_probe.c` also expands the conversion macros (`lua_integer2str`,
  `lua_number2str`, `lua_number2strx`, `lua_pointer2str`, `lua_str2number`,
  `lua_strx2number`, `lua_getlocaledecpoint`) and calls `luaL_checkversion_`
  with a wrong version, with wrong numeric sizes, and with PUC's numeric
  stamp; each must raise its message, the last with the ABI rebuild hint.
- `tests/capi/test_capi.c` checks the `lua_setcstacklimit` no-op contract.
- `tests/ref/build-puc54-libs.sh` builds the `tests/corpus/puc54/libs` C
  fixtures twice, into `tests/capi/build/corpus-libs/{puc,jit}`. The harness
  installs the arm's build in the test's private `libs/` directory and sets
  that arm's `LUA_CPATH` to it, so `attrib.lua` (which uses `loadlib` with a
  relative path) stays green in modes A, B and R.
