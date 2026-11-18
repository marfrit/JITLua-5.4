# DIFFERENCES.md audit — 2026-11

Entry-by-entry audit of `docs/DIFFERENCES.md` against PUC Lua 5.4.9 (2026-11-19).
Docs and probe tests only; no VM, JIT or library code was changed.

## Method

- PUC side checked in the vendored 5.4.9 sources (the same tarball
  `tests/ref/fetch-ref.sh` builds; `manifest.txt` pins the lua.org ftp sha256
  `2335b6c5…`), unpacked outside the worktree. Manual quotes are from the
  5.4.9 `manual.html` shipped in that tarball.
- JITLua side checked in this tree (branch `diffaudit` at main `7b85747e`).
- Observable claims were probed on one x86_64 box and one arm64 box, ours with
  `-joff` and `-jon`, and the PUC reference binary (harness mode A). New
  permanent probes: `tests/capi/probe_549.c` (C API: `lua_setcstacklimit`,
  `lua_getextraspace`, `lua_topointer` string identity), `tests/d54/env_05_envvalue.lua`,
  `tests/d54/meta_05_nummt_i64.lua`, `tests/d54/tbl_04_create.lua`.
- Harness final state (full corpus, modes A+B, both arches): 169 PASS / 0 FAIL /
  11 XFAIL / 0 XPASS / 12 SKIP / 0 BAD / 0 TIMEOUT. `tests/capi/run.sh`:
  204 + 14 checks, 0 failures, both arches; the PUC side of `probe_549` matches
  on the parity lines.

## Verdict per entry

"Probe" = x64/arm64 result (our `-joff`, our `-jon`, PUC ref).

| # | Entry | PUC 5.4.9 evidence | JITLua-5.4 evidence | Probe (x64 / arm64) | Verdict | Action |
|---|-------|--------------------|---------------------|---------------------|---------|--------|
| 1 | FORK string interning | `lstring.c` `luaS_newlstr`: long strings via `luaS_createlngstrobj` (fresh object, not tableed); short strings interned | `lj_str.c` `lj_str_new`/`lj_str_alloc`: every string goes through the interning table | probe_549: longstr/gsub `same` = ours 1 / PUC 0; shortstr 1/1; both arches | correct as written | kept; C probe reference added |
| 2 | FORK `string.dump` format | `lundump.c` `check_version` (l. 295): signature `\x1bLua`, byte 3 `'u'`, `LUAC_VERSION` 0x54 | `lj_bcwrite.c` `bcwrite_header`; `lj_bcdump.h`: HEAD3 = 0x4a (`'J'`), `BCDUMP_VERSION` 0x84 — PUC rejects at byte 3 | `dump_03_version.lua` XFAIL A, both arches; mode R green | correct as written | kept |
| 3 | PENDING arbitrary `_ENV` | `lbaselib.c` `load_aux`: any value accepted, stored as 1st upvalue via `lua_setupvalue`; `testes/calls.lua:359` asserts `load("return _ENV",nil,nil,123)() == 123` | `lib_base.c` `load_aux`: only `tvistab`/`tvisnil` env handled; others silently ignored | new `env_05_envvalue.lua`: A differs both arches (PUC keeps number/string/function/boolean; ours returns the global table); B passes both | correct as written | kept; new test + known-bad row |
| 4 | PENDING pcall nesting + `__call` chain | `ldo.c` `tryfuncTM` (l. 437, object placed below the metamethod), `luaD_pretailcall` retry; `llimits.h:255` `LUAI_MAXCCALLS` 200 | known-bad `calls.lua` A/B (branch `wip-calls-vm`); chain probe: single-level `__call` matches PUC, but `outer.__call = inner-table` raises `attempt to call a table value` while PUC calls `inner.__call(inner, outer, 7, 8)` | `calls.lua` XFAIL A+B both arches; chain probe x64 (joff = jon) | correct as written | kept (named VM gap) |
| 5 | IMPL-DEFINED sparse-table border | manual §3.4.7: "When t is not a sequence, #t can return any of its borders. (The exact one depends on details of the internal representation of the table…)" | `lj_tab` array-growth policy differs from PUC's `alimit` hint | `tbl_03_border_divergence.lua` XFAIL A both arches | correct as written | kept |
| 6 | `__gc` only userdata, not tables | manual §2.5.3: "You can set garbage-collector metamethods for tables and, using the C API, for full userdata" — stated as a standard feature; no optionality sentence exists | finalizers run only for userdata | `gc_01_tbc_gc.lua` XFAIL A both arches | **wrong tag**: IMPL-DEFINED has no supporting manual sentence | retagged PENDING (named VM gap, phase0 "table __gc finalizers"); known-bad row retagged |
| 7 | EXTENSION `table.create` | `ltablib.c` `tab_funcs` (l. 414–423): concat/insert/pack/unpack/remove/move/sort — no `create` | `lib_table.c`: no `create` either (maxn/insert/concat/sort/pack/move/unpack + NOREG new/clear) | new `tbl_04_create.lua`: `type(table.create)` = nil on **both** binaries, both arches → mode A passes | **wrong text**: parity, not a difference | entry **deleted** (see list); `tbl_04_create.lua` kept as parity guard |
| 8 | PENDING tail-call error names | `lauxlib.c` `luaL_argerror` (level 0 `"n"` + `pushglobalfuncname`); `ldebug.c` `getfuncname`/`funcnamefromcall` | frame reuse → loaded-module fallback | probe: PUC `to 'rep'`/`to 'move'` for non-tail **and** tail; ours matches non-tail, tail gives `to 'string.rep'`/`to 'table.move'` (joff = jon, x64); `err_02_tailname.lua` XFAIL A both arches | correct as written | kept |
| 9 | PENDING `istailcall` without hook | `ldebug.c:358`: `ar->istailcall = (ci) ? ci->callstatus & CIST_TAIL : 0;` — filled without a hook | `lj_debug.c:254,297,672`: Fable tail marks only while a call hook is installed | `db.lua` (line 619) XFAIL A both arches | correct as written | kept |
| 10 | IMPL-DEFINED debug level 2 in `__close` (error path) | manual §6.10 level definition ("level 1 is the function that called getinfo … and so on") does not specify C-frame counting; PUC walks the C-frame chain (pcall C function visible) | no C frame for `pcall()` (documented in the `close_03/04` headers) | `close_03/04` pass A+B both arches (PUC assertion left out, per header) | correct as written | kept |
| 11 | IMPL-DEFINED yield from `__close` on error path | `ldo.c` `luaF_close` "can yield or raise an error" (l. 708, protected-close path); PUC `locals.lua` block "yielding inside closing metamethods after an error" works; manual §3.3.8 specifies `__close` *error* handling, not yield semantics on the error path; §4.5: a yield across an API call is an error except through the three `k` functions | `__close` on the error path runs inside the C-level protected call → "attempt to yield across a C-call boundary" | `close_04` passes A+B both arches | correct as written | kept |
| 12 | PENDING `lua_setcstacklimit` | `lstate.c:99–102`: `UNUSED(L); UNUSED(limit); return LUAI_MAXCCALLS;` — a no-op (200, `llimits.h:255`); not even documented in the 5.4.9 manual | `lj_api.c:1237–1241`: byte-for-byte the same no-op | probe_549: `setcstacklimit(300)=200`, `setcstacklimit(0)=200` on **both** binaries, both arches | **obsolete**: entry claims "PUC sets a new C-stack limit and returns the previous one" — true of 5.4.0–5.4.3, not of 5.4.9. This is parity | entry **deleted** (see list) |
| 13 | FORK `lua_toclose` slots close at yield | `lapi.c` `lua_toclose` (l. 1271); C continuation stored in the `CallInfo` (`lapi.c` `lua_pcallk`: `ci->u.c.k = k`) — the slot stays pending across the resume | `lj_api.c:1815`: no continuation frame, slot must close at yield | `tests/capi` `test_toclose`: part of 204 checks, 0 failures, both arches | correct as written | kept |
| 14 | EXTENSION `luaL_Buffer` PUC layout | `lauxlib.h`: struct + `#define luaL_prepbuffer(B) luaL_prepbuffsize(B, LUAL_BUFFERSIZE)` (l. 224) | `src/lauxlib.h`: identical struct and macro (l. 196) | capi buffer checks (`grow_buffer_c`, `addvalue_boxed_c`) pass both arches | **obsolete as a PUC-section entry**: the layout *is* PUC parity, which the file's own rule says is not listed; the ABI note belongs to the 2.1 section | entry **deleted** from the PUC section; ABI note moved into the "Added 5.4 standard library / C API" entry (see list) |
| 15 | FORK 5.4 continuation API, `k` never called | manual §4.5: continuations are called after a yield; `lapi.c` `lua_pcallk` stores `k`/`ctx` in the `CallInfo` | `lj_api.c:1713–1715` (`lua_callk` ignores `k`), `lj_api.c:1855–1858` (`lua_yieldk` refuses non-NULL `k`) | `tests/capi` `test_continuations`: 204 checks pass, both arches | correct as written | kept |
| 16 | PENDING number metatable vs boxed int64 | `lstate.h:299`: `Table *mt[LUA_NUMTYPES]` — one slot, int and float share `LUA_TNUMBER`; `ltm.c` `luaT_gettmbyobj` (l. 71) | `lj_api.c` `lua_setmetatable` (l. 1563): one base metatable per value tag; `lj_obj.h:354` `tvisi64` = `UDTYPE_I64BOX` userdata (not number-tagged); 47-bit inline values keep the number tag | new `meta_05_nummt_i64.lua`: A differs both arches — `(1):floor()` and runtime `(1<<45)+3` work, literal `35184372088835` and `(1<<50)+3` raise, `getmetatable` nil for boxed; B passes both | correct as written, refined: literals beyond int32 materialize as boxes even when the value fits in 47 bits | kept; text refined; new test + known-bad row |
| 17 | PENDING `lua_getextraspace` | `lua.h:371` macro; `luaconf.h:760` `LUA_EXTRASPACE` = `sizeof(void *)`; `lstate.c:36` `LX.extra_` reserved per thread | no `LUA_EXTRASPACE`/`lua_getextraspace` in `lua.h` (absent) | probe_549: ours `extraspace absent`; PUC `nonnull=1 threadcopy=1 size=8`; both arches | correct as written | kept; C probe reference added |
| 18 | FIXED arm64 `bit.*` shift | n/a (regression record) | commits `cb2f6da2`/`6e4d7bb9` exist; `docs/bug-bit-shift-arm64.md`; `tests/lib/bit-checkint.lua` exist | `bit-checkint` in the lib suite; harness green both arches | correct as written | kept |
| 19 | FIXED `math.lua` mode B x64 | n/a | `docs/bug-math-random-jit.md`; `tests/lib/math-random-jit.lua` exist | `puc54/math.lua` passes A+B on the x64 box | correct as written | kept |
| 20 | PENDING `closure.lua` mode B arm64 | n/a | known-bad row | arm64: mode B still times out — now even the 20 s harness cap (was the 600 s figure at triage); x64 B passes | correct as written | kept |
| 21 | PENDING `heavy.lua` OOM | n/a | known-bad row; excluded from the default corpus (SKIP in the harness) | SKIP both arches | correct as written | kept |
| 22 | PENDING classic benchmarks vs stock 2.1 | n/a | `docs/perf-regression-2026-11-17.md`, `docs/bench-classic-2026-11-17.md` exist | out of probe scope | correct as written | kept |
| 23 | EXTENSION 5.4 operators/bytecodes (vs 2.1) | `//`, bitwise, `<close>`, FORI/FORL, 64-bit consts all standard 5.4 | `lj_bc.h`: `IDIV`, `BAND/BOR/BXOR/BSHL/BSHR`, `VARG`, `FORI/FORL`, `TBC/TBCCLO`, `KI64` | 5.4-syntax corpus tests pass A+B both arches | correct as written (the entry lists PUC-style op names; the fork's opcode names differ slightly — cosmetic) | kept |
| 24 | EXTENSION `goto`/label scoping, return-ends-block (vs 2.1) | standard 5.4 | `goto_01_labels.lua`, corpus `goto` tests | pass A+B both arches | correct as written | kept |
| 25 | FORK ASCII-only identifiers (vs 2.1) | PUC 5.4 identifiers: ASCII letters/digits/`_` (`llex.c` `isalpha`/`isdigit` on `LUA_CTYPE`) | `lj_lex.c:474` `lex_isident5` (ASCII alpha/digit/`_`); bytes 128–255 carry only the `LJ_CHAR_IDENT` bit (`lj_char.c:34–48`), which the 5.4 scanner no longer uses for identifiers | `lex_02_identifiers.lua` passes A+B both arches (same syntax error, normalized) | correct as written (note: the header comment in `lj_char.c` still claims 128–255 are identifier characters — stale comment, not touched in this docs-only audit) | kept |
| 26 | FORK `jit.version` / `luajit -v` string (vs 2.1) | n/a | `luajit_rolling.h:33`: `JITLua-5.4 (LuaJIT 2.1.ROLLING)`, relver substituted at build from `.relver` | version banners compared in the harness | correct as written | kept |
| 27 | EXTENSION 5.4 standard library (vs 2.1) | PUC 5.4 has **global** `rawlen` (`lbaselib.c:157`, registered l. 521); there is no `table.rawlen` | `lib_base.c:239` `LJLIB_CF(rawlen)` — global, same placement as PUC | corpus `utf8_01`, `str_02_pack`, `math_*`, `os_*`, `pkg_02` pass | **wrong text**: `table.rawlen` should be `rawlen` | text fixed |
| 28 | EXTENSION 5.4 C API (vs 2.1) | the listed functions exist in 5.4 | all present; `lauxlib.h:48–51` (`luaL_requiref`/`luaL_tolstring`/`luaL_typeerror`); `luaconf.h` includes `<limits.h>` (capi `INT_MAX` check) | capi suite: 204 checks, 0 failures, both arches | correct as written | kept; the moved `luaL_Buffer` ABI note (entry 14) appended |
| 29 | EXTENSION `lua_getfenv`/`setfenv` kept (vs 2.1) | removed from PUC 5.4 (absent from `ldblib.c`, `lua.h`, the manual) | `src/lua.h:227,241` | `env_01_fenv.lua` passes A+B both arches | correct as written | kept |
| 30 | EXTENSION `jit.*`, `bit.*`, ffi/cdata, `bcsave`, `-j/-O/-b` (vs 2.1) | n/a | `jit` table present; ffi loads via `require("ffi")` (`:preload:`, not a global — the entry does not claim one) | ffi/bit corpus tests pass | correct as written | kept |
| 31 | FORK `bit.*` hybrid int64 rule (vs 2.1) | n/a (fork design, `docs/ffi-int-semantics.md`) | `lib_bit.c:30–58` (all-number calls wrap int32; 64-bit cdata operand converts natives exactly) | probe x64, `-joff` = `-jon`: `bit.band(2^32+1, 0xffffffff00000000)` = 0; `bit.band(uint64 max, (1<<40)\|0xff)` = `1099511628031ULL` — exactly the entry's examples; `tests/lib/bit-checkint.lua` | correct as written | kept |
| 32 | EXTENSION FFI source-literal suffixes (vs 2.1) | PUC rejects `1ULL` (`llex.c` `read_numeral`: "malformed number") | `lex_03_ffi_suffix.lua` | passes A+B both arches | correct as written | kept |
| 33 | EXTENSION LuaJIT pattern-matching implementation (vs 2.1) | 5.4 pattern semantics | `str_03_patterns.lua` | passes A+B both arches | correct as written | kept |
| 34 | EXTENSION `string.dump` format, `-b`/`bcsave` (vs 2.1) | n/a | see entry 2 | `dump_03_version.lua` XFAIL A (private format), mode R green, both arches | correct as written | kept |

## New entry added (new difference found by this audit)

- **PENDING — bare-state segfault** (added to the "Language and VM" section):
  parsing or running a chunk that names a global on a state whose base library
  is not installed segfaults; PUC 5.4.9 runs it. Root cause: the 5.4 `_ENV`
  GGET special case reads the interned `_ENV` string from `GCROOT_ENVSTR`
  (`src/lj_parse.c:1383`), which is installed only when the base library is
  opened (`src/lib_base.c:868`); `lj_record.c:3036` reads it as well.
  Repro (both arches, exit 139; x64 backtrace ends in `var_lookup` ←
  `parse_chunk` ← `lua_loadx` ← `luaL_loadstring`):

  ```c
  #include <lua.h>
  #include <lauxlib.h>
  int main(void) {
    lua_State *L = luaL_newstate();          /* no luaL_openlibs */
    luaL_dostring(L, "g = 1");               /* SIGSEGV here */
    return 0;
  }
  ```

  This is a defect, not a deliberate divergence; it is recorded as PENDING so
  C-API users (embedding without the standard libraries) can find it. No
  permanent crash test was added — the harness would go red; the repro above
  is the check until it is fixed. `tests/capi/probe_549.c` opens the standard
  libraries for this reason (noted in its header).

## Deleted entries (explicit list, per the audit rule)

1. `EXTENSION` `table.create` is a LuaJIT extension (nil in PUC 5.4) —
   **wrong text**: `type(table.create)` is nil on PUC 5.4.9 **and** on this
   fork (both arches); stock LuaJIT 2.1 has no `table.create` either. Parity
   is not listed per the file's own rule. Replaced by the parity test
   `tests/d54/tbl_04_create.lua` (passes modes A+B).
2. `PENDING` `lua_setcstacklimit` … "PUC sets a new C-stack limit and returns
   the previous one" — **obsolete**: PUC 5.4.9 (`lstate.c:99`) is a no-op
   returning `LUAI_MAXCCALLS` (200), identical to `lj_api.c:1237`. The claim
   described 5.4.0–5.4.3. Parity confirmed by `probe_549` on both binaries and
   both arches.
3. `EXTENSION` `luaL_Buffer` uses the PUC 5.4 layout … (PUC section) —
   **obsolete as a PUC difference**: the layout and the `luaL_prepbuffer`
   macro match PUC 5.4.9 exactly (source-verified). The auxlib-ABI sentence
   ("C modules compiled against an older JITLua-5.4 auxlib must be
   recompiled") was moved, verbatim in meaning, into the "Against stock
   LuaJIT 2.1 → Added 5.4 standard library / C API" entry, where ABI changes
   relative to stock belong.

## Other changes

- Entry 6 retagged `IMPL-DEFINED` → `PENDING` (manual §2.5.3 mandates table
  finalizers; no sentence allows omitting them — the tag legend has no
  IMPL-DEFINED support for it). `tests/known-bad.tsv` row retagged to match.
- Entry 27 text: `table.rawlen` → `rawlen` (PUC 5.4 and this fork both have a
  *global* `rawlen`; there is no `table.rawlen`).
- Entry 16 text refined with the probe findings (47-bit inline values do get
  the number metatable; literals beyond int32 box even inside the 47-bit
  range) and a test reference.
- Test/probe references added to entries 1, 3, 16, 17.
- `tests/known-bad.tsv`: two rows added (`env_05_envvalue.lua` A,
  `meta_05_nummt_i64.lua` A), one retagged (`gc_01_tbc_gc.lua` A).

## Observations (no action taken — outside docs/tests scope)

- `tests/d54/tbl_01_lib.lua` line 42 (the old `table.create` probe) is
  unreachable: the file aborts at line 34 on **both** binaries (a `select`
  error in `va()`), so mode A passed without ever testing `table.create`.
  `tbl_04_create.lua` now covers the fact.
- The header comment in `src/lj_char.c` ("Identifiers include the characters
  128–255, too") is stale with respect to the 5.4 scanner; the table itself
  is only used for the ASCII classes by `lex_isident5`.
- `closure.lua` mode B on arm64 now exceeds even the 20 s harness timeout
  (the known-bad row quotes the original 600 s triage figure).
