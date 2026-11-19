# Downstream compatibility round 2 (2026-11)

Ten third-party Lua&nbsp;5.4 libraries that ship their own test suite, run under
PUC&nbsp;5.4.9, JITLua `-joff` and JITLua `-jon`, on one arm64 and one x86_64
build host. This complements the Prosody rounds with a broad library sweep and
exercises the C API through three C modules. No interpreter change: this round
only records what the suites find.

Branch `downstream2` (from `integ6`, merged `main` before the final run). The
run scripts were kept out of the tree; the per-run stdout/stderr and
`results.json` stayed on the build hosts.

## Method

- PUC 5.4.9 built from the vendored `tests/ref` tarball.
- JITLua built from the branch tree; every C module was compiled against the
  headers of the interpreter it runs on (`tests/ref/src/lua-5.4.9/src` for
  PUC, `src/` for JITLua).
- Arms: `puc`, `joff` (`-joff`), `jon` (`-jon`), and `jon-gc` (`-jon` with
  `collectgarbage("setpause",100)` + `"setstepmul",1000` via `LUA_INIT`) for
  suites that finish under 90 s.
- Suites use their own runner: a plain script, luaunit, or busted 2.2.0
  (pinned stack, TAP output).
- Hosts: one arm64 build host (20 cores) and one x86_64 build host
  (4 threads). Both are offline; no DNS was used and no host network setup was
  changed.

## Pinned inputs

Pure Lua:

| library | version | runner | source | sha256 |
|---|---|---|---|---|
| argparse | 0.7.1 | busted | codeload.github.com/luarocks/argparse tag 0.7.1 | d344e49404c3e7b3e7fa4fe6741c106f25909d9b24923cb08dcceda1f9754809 |
| dkjson | 2.8 | plain `jsontest.lua` | `dkjson-2.8-1.src.rock` (vendored earlier) | 3d8de09cd43a60a005ac769ee1cedc515952c892d63cba9ac925ed02afc98091 |
| inspect.lua | 3.1.3 | busted | vendored `inspect-3.1.3.tar.gz` | 43386a613f9916186af4919f36392d8b8dad8c4428a5f8c85ebac80acba71eeb |
| luaunit | 3.4 | `run_unit_tests.lua` | vendored `luaunit-3.4.tar.gz` | b8aea5826f09749d149efa8ef1b13f81e6a9fc6abfbe4c1cbf87a558a6d4e8d0 |
| lume | 2.3.0 | plain `test/test.lua` | codeload.github.com/rxi/lume tag v2.3.0 | e74dfa2feeb639f0d26a8014ab5e0344f3c457e029719e659710896be8636461 |
| middleclass | 4.1.1 | busted | codeload.github.com/kikito/middleclass tag v4.1.1 | d01e5af2a61eeb8c9533f8b3b0fa665bd8ad693c2b9fb297b20e3f9e16d85085 |
| serpent | 0.30 | plain `t/test.lua` | vendored `serpent-0.30.tar.gz` | ebc8d9121a793ae2df69ca03b7f9d2ad0e82e385d4ed0d452eedd305c1b93b22 |

C modules:

| library | version | deps | source | sha256 |
|---|---|---|---|---|
| lpeg | 1.1.0 | — | vendored `lpeg-1.1.0.tar.gz` | 4b155d67d2246c1ffa7ad7bc466c1ea899bbc40fef0257cc9c03cecbaed4352a |
| lua-cjson | 2.1.0.14 | — | vendored `lua-cjson-2.1.0.14.tar.gz` | 14cac5c7a4520b33449a1fc961344556b8b6a2a2c6b739b0e46e3002e6e605bc |
| lua-zlib | 1.2 | zlib 1.3.1 | codeload.github.com/brimworks/lua-zlib tag v1.2 | 26b813ad39c94fc930b168c3418e2e746af3b2e80b92f94f306f6f954cc31e7d |
| zlib (for lua-zlib) | 1.3.1 | — | zlib.net/fossils/zlib-1.3.1.tar.gz | 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23 |

The vendored tarballs came from the earlier Prosody rounds; the GitHub/codeload
tarballs have no published checksum, so the sha256 above is of the pinned tag
tarball. zlib's value is the published one. busted 2.2.0 with luassert 1.9.0,
say 1.4.1, lua_cliargs 3.0-2, mediator_lua 1.1.2, Penlight 1.14.0, lua-term
0.8 and luasystem 0.6.3 is the harness for the busted suites.

## Results

`P/F` is the suite's own pass/fail count; `rc` marks suites that only report an
exit status. `jon-gc` is `-jon` with GC stress.

### arm64

| library | puc | joff | jon | jon-gc |
|---|---|---|---|---|
| argparse | 192/0 | 192/0 | 192/0 | 192/0 |
| dkjson | rc0 | rc0 | rc0 | rc0 |
| inspect.lua | 48/0 | 49/0 | 49/0 | 49/0 |
| lpeg | rc0 | rc0 | rc0 | rc0 |
| lua-cjson | 104/1 | 104/1 | 104/1 | 104/1 |
| lua-zlib | 17/0 | 17/0 | 17/0 | 17/0 |
| luaunit | 205/1 | 204/2 | 204/2 | 204/2 |
| lume | 264/0 | 263/1 | 263/1 | 263/1 |
| middleclass | 128/2 | 128/2 | 128/2 | 128/2 |
| serpent | rc0 | rc0 | rc0 | rc0 |

### x86_64

Identical row for row to arm64 (same counts and the same failing test names).

## Differences vs PUC 5.4.9

### 1. lume 2.3.0 — the `->` short-function expression (known divergence)

lume's `lambda` test builds `return function(a,b) return a->b end` and expects
`load` to reject it. PUC rejects it; JITLua accepts it because `->` is the
inherited LuaJIT "Short Function Expression" backported from LuaJIT 3.0
(`doc/extensions.html`). Minimal reproducer:

```lua
local ok, f = pcall(load, "return a->b")
print(ok, type(f))          -- PUC: false string | JITLua: true function
print(pcall(load, "return 1->2"))  -- both fail, with different wording
```

Classification: **known divergence** (inherited LuaJIT extension; documented in
`doc/extensions.html`, but not in `docs/DIFFERENCES.md` or
`tests/known-bad.tsv`). Recorded as `tests/d54/parse_arrow_shortfunc.lua`,
`XFAIL` in mode A, so the next session can decide to add the EXTENSION row or
gate the syntax. It is the only PUC/JITLua behavioral difference a suite
reported.

### 2. luaunit 3.4 — `jit.version` version detection (known FORK + suite issue)

luaunit picks its number-formatting expectation with
`_LUAVERSION < 'Lua 5.4'`, where `_LUAVERSION = jit.version or _VERSION`.
`jit.version` is `"JITLua-5.4 (LuaJIT 2.1.ROLLING)"`, which sorts *below*
`"Lua 5.4"` (first byte `J` < `L`), so luaunit takes its pre-5.4 branch and
expects `prettystr(1.0) == "1"`. JITLua formats integral floats as `"1.0"`,
the PUC 5.4 result, so the test fails. Minimal reproducer:

```lua
local v = (jit and jit.version) or _VERSION
print(v, v < "Lua 5.4")     -- PUC: "Lua 5.4" false | JITLua: "JITLua-..." true
```

Classification: **known divergence** (`jit.version` is a listed FORK) plus a
suite version-detection issue; no interpreter change. The other luaunit
failure, `TestLuaUnitExecution.testWithRepeat`, fails on PUC as well.

### 3. lua-zlib — `LUAL_BUFFERSIZE` (known divergence, output only)

`lua_zlib.c` exposes `_TEST_BUFSIZ = LUAL_BUFFERSIZE`; the test description
therefore reads `1024` (`16*sizeof(void*)*sizeof(lua_Number)`) on PUC and
`8192` (`BUFSIZ`) on JITLua. All 17 zlib checks pass on every arm; only the
printed size differs. Classification: known divergence in the C API constant
(LuaJIT keeps its auxlib ABI buffer size).

### 4. Table iteration order (implementation-defined)

`dkjson`, `lua-cjson` and `serpent` print tables whose key order differs
between PUC and JITLua, e.g.

```lua
for k in pairs({ [1]="a", [1000]="x" }) do io.write(k, " ") end
```

The suites still pass (they round-trip or compare decoded values).
Classification: implementation-defined `pairs` order, not a bug. `serpent`
additionally prints a `string.dump` blob via `loadstring`, which is the known
private dump FORK.

### 5. inspect.lua — extra test on JITLua

PUC runs 48 checks, JITLua 49: JITLua adds "inspect works with luajit cdata",
which PUC skips. Expected; no failure.

## Failures identical on PUC and JITLua (suite / test environment)

- **lua-cjson** 104/105 on every arm: test 80 "Decode all UTF-16 escapes"
  needs the generated `utf8.dat` fixture ("Failed to load utf8.dat - please run
  genutf8.pl"). Fixture not shipped; fails on PUC too.
- **middleclass** 128/130 on every arm: two `__ipairs` tests. `__ipairs` was
  removed in Lua 5.4; the suite still expects the 5.2 metamethod.
- **luaunit** `testWithRepeat`: a luaunit self-test that fails on PUC too.
- **argparse**: first run was 174/192 because the spec shells out to a `lua`
  on `PATH` ("sh: 1: lua: not found"). With a per-arm `lua` wrapper the suite
  is 192/192 on every arm; that was a test-environment fix in the runner, not a
  library difference.

## Recorded candidate

`tests/d54/parse_arrow_shortfunc.lua` + a `tests/known-bad.tsv` entry (mode A),
for the `->` divergence in item 1. Verified on arm64:
`tests/harness.sh --mode A --corpus tests/d54 --filter parse_arrow` reports
`XFAIL 1, FAIL 0`. No other candidate was warranted: items 2-5 are already
covered by the `jit.*` / dump FORKs or are implementation-defined, and the
identical failures are suite issues rather than interpreter bugs.

---

# Downstream compatibility round 3 (2026-11)

Large Lua code bases rather than library test suites: the Teal compiler, Fennel
(the compiler and its suite), MoonScript, and busted's own self-suite. Same
protocol as round 2 (pinned version + sha256, PUC 5.4.9 / JITLua `-joff` /
`-jon` / `-jon`+GC stress, arm64 and x86_64, no interpreter change). LuaRocks
was dropped before the run: its suite needs a hererocks-style test environment
(`spec/util/test_env.lua` searches for a full Lua tree via `LUA`/`LUA_DIR`);
it is not runnable offline from the pinned tarball alone.

## Pinned inputs

| project | version | kind | source | sha256 |
|---|---|---|---|---|
| Teal (`tl`) | 0.24.8 | compiler + busted suite | codeload.github.com/teal-language/tl tag v0.24.8 | 8d7a143fd67d71dca5dad132a0e1443be6c013c54de2884adf4f3ed3b2cef022 |
| Fennel | 1.6.1 | compiler + `test/faith` suite | codeload.github.com/bakpakin/Fennel tag 1.6.1 | 8bf46040ea9554f4c132de6cb6bf26a30ce8f7c99e58e82bc971c533d91ecd71 |
| MoonScript | 0.8.0 | compiler + busted suite | codeload.github.com/leafo/moonscript tag v0.8.0 | 0458ba86359c9089f823f81e4198ea3f7d57c2f2773fb8a1364940ebdd802ac5 |
| loadkit (MoonScript suite loader) | 1.1.0 | dep | codeload.github.com/leafo/loadkit tag v1.1.0 | 39742dd5db94f13886810cf69fc9b3db89bba3180c060384136115c9da431196 |
| LuaRocks | 3.13.0 | not run (see above) | codeload.github.com/luarocks/luarocks tag v3.13.0 | 71adfead6966e2912034b8fb8103dd343c3adc6c91a276f1d209eebbaefe3a15 |

lpeg 1.1.0 and the busted 2.2.0 stack are reused from round 2; argparse 0.7.1
is used by the Teal and MoonScript CLIs. MoonScript's `native.c` parser is
compiled per interpreter against its headers.

## Results

`P/F` is the suite's own count; `rc` where the suite only reports an exit
status. `jon-gc` is `-jon` with GC stress.

### arm64

| project | puc | joff | jon | jon-gc |
|---|---|---|---|---|
| teal | 1645/1 | 1645/1 | 1645/1 | 1645/1 |
| fennel | 151/1 | 150/2 | 150/2 | 150/2 |
| moonscript | 242/0 | 242/0 | 242/0 | 242/0 |
| busted | 1676/1 | 1676/1 | 1676/1 | 1676/1 |

### x86_64

| project | puc | joff | jon | jon-gc |
|---|---|---|---|---|
| teal | 1645/1 | 1645/1 | 1645/1 | 1645/1 |
| fennel | 151/1 | **segfault (139)** | **segfault (139)** | **segfault (139)** |
| moonscript | 242/0 | 242/0 | 242/0 | 242/0 |
| busted | 1676/1 | 1676/1 | 1676/1 | 1676/1 |

## Self-compile timing (median of 3, ms) and output stability

The compiler runs under the arm it is timed on; the generated output is
compared byte for byte across arms.

| project | arm64 puc | arm64 joff | arm64 jon | x86_64 puc | x86_64 joff | x86_64 jon | output |
|---|---:|---:|---:|---:|---:|---:|---|
| Teal `tl gen tl.tl` | 590 | 472 | 492 | 1887 | 1260 | 1261 | byte-identical, 175 files |
| Fennel `fennel.lua` | 387 | 304 | 495 | 1532 | 1115 | 2055 | byte-identical |
| MoonScript `moonc moon/ moonscript/` | 79 | 66 | 77 | 390 | 301 | 356 | byte-identical, 62 files |

JITLua `-jon` is 1.2-1.5x faster than PUC on Teal and MoonScript, and about
equal on Fennel on arm64; the x86_64 host is a 4-thread NUC and noisier. The
compiler output is interpreter-independent in all three cases.

## Differences vs PUC 5.4.9

### 1. OPEN — x86_64 JITLua segfault with a to-be-closed table (real bug)

Fennel's `test.core` → `test-destructuring` segfaults under JITLua on x86_64
(both `-joff` and `-jon`), while PUC completes all 66 assertions; arm64 is
unaffected. The reduced Fennel reproducer is `test/init.lua test.red` with
`test.red` = the `test/core.fnl` header plus `test-destructuring`; the crash
needs the `{:toBeClosed true}` option (real `<close>` codegen).

Minimal Lua reproducer (x86_64, `-joff` and `-jon`, rc 139; PUC prints
`true true`):

```lua
local function f()
  local t = {}
  do
    local t2 <close> = setmetatable({}, {__close = function() t.closed = true end})
    t2.what = "ever"
  end
  return t.closed
end
print(pcall(f))   -- PUC: true true | x86_64 JITLua: SIGSEGV
```

It crashes in both JIT modes, so it is an interpreter/GC issue, not a JIT
miscompile; it is x86_64-only. No `tests/d54` entry was added: `known-bad.tsv`
has no architecture qualifier, so a test for this would be XFAIL on x86_64 but
XPASS on arm64 and would fail the strict arm64 gate. The next session should
fix it, then add a cross-architecture test.

### 2. Fennel `test-getinfo` — `debug.getinfo(1,"t").istailcall` (known PENDING)

JITLua adds one failure on every arm: Fennel's `test-getinfo` expects
`istailcall = true` for a tail call; JITLua reports `false` without a call
hook. Already recorded in `docs/DIFFERENCES.md` as PENDING (db.lua line 619).

```lua
local function f() return debug.getinfo(1, "t").istailcall end
local function g() return f() end
print(g())   -- PUC: true | JITLua: false
```

### 3. Failures identical on PUC and JITLua (suite / environment)

- Teal `spec/api/load_spec.lua` (1 failure): runs the `tl` CLI through
  `io.popen`; identical on PUC after the CLI gets argparse on `LUA_PATH`.
- Fennel `test-lua-plugin` (1): fails on PUC too (plugin fixture).
- busted `configfile for luacov` (1): the luacov output handler is not
  installed in the pinned stack.
- MoonScript: 242/242 on every arm.

## Open items for the next round

1. x86_64-only JITLua segfault on a to-be-closed table with `__close`
   (minimal repro above); needs a fix and then a d54 test with an
   architecture-aware known-bad policy (or a fix that makes it pass on both).
2. Teal `spec/api/load_spec.lua` failure: classify definitively (it is
   identical on PUC, but the exact cause was not traced).
3. LuaRocks suite: needs a hererocks-style `LUA`/`LUA_DIR` test environment;
   not run here.
4. `debug.getinfo(...).istailcall` remains PENDING (known, unchanged).
