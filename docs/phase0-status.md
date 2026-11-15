# Phase 0 status / breadcrumbs (LuaJIT-5.4)

Updated: 2026-11-15 (session 1). Read this first when resuming.

## Repo layout / git decision
- Working tree: `/home/mfritsche/src/LuaJIT-5.4` (branch `main`).
- **Bare origin (canonical, "for the time being")**: `/home/mfritsche/src/git/LuaJIT-5.4.git`
  (`git remote origin`). No GitHub remote yet. Push with `git push -u origin main`.
- `upstream` remote = https://github.com/LuaJIT/LuaJIT, branch `v2.1` imported with full history.
- **Base commit: `63c8f1a9b479ba5518cf6a170ff7729178bc3cfd`** ("DynASM: Escape paths in #line directive").
  MISSION says "tag v2.1" — **LuaJIT has NO tags at all**; v2.1 is a branch. Deviation recorded.
- Host: ampere, aarch64 Arch, 8 cores. LuaJIT 2.1 builds natively (`make -j8` → `src/luajit`,
  version `LuaJIT 2.1.1794386141`). ARM64 backend is native here; x64 CI must run elsewhere.

## Reference (oracle)
- PUC-Lua 5.4.7 built: `tests/ref/bin/lua54ref`, `tests/ref/bin/luac54ref`.
- Rebuild: `tests/ref/fetch-ref.sh` (pins in `tests/ref/manifest.txt`;
  lua.org sha256 `9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30`).
- Tarball cache: `~/.cache/luajit54-dl/`.
- Corpus `tests/corpus/puc54/` = `testes/` from lua/lua GitHub tag v5.4.7,
  commit `1ab3208a1fceb12fca8f24ba57d6e13c5bff15e3` (no official tests tarball for 5.4.7).

## Harness (done)
- `tests/harness.sh` → `tests/lib/runner.py` (python3).
  Modes: **A** ref vs ours `-joff`; **B** ours `-jon` vs `-joff` (`--opt-levels 0,1,2,3` → `-O<n>`);
  **R** direct vs `tests/lib/dump_reload.lua` (string.dump→load→run).
  `--mode both|all`, `--corpus`, `--filter`, `--jobs`, `--timeout`, `--update-known-bad`,
  `--strict` (XPASS fatal), `--verbose`, `--list`.
- CLI facts: LuaJIT uses `-joff`/`-jon` (NOT `--jit=off`), opt level via `-O0..-O3`.
- Normalization: whitespace collapse, CRLF, `0x[0-9a-f]{5,}`→`0xADDR`, program-name prefix→`lua:`,
  absolute paths→basename, **tracebacks cut**. Number formatting/error wording NOT normalized.
- Child env: `LC_ALL=C TZ=UTC`, isolated `LUA_PATH*`/`LUA_CPATH*`, `LUA_INIT=` empty.
  cwd = test's own directory, script passed as basename (so chunk names match).
- Pre-flight: every corpus file must pass `luac54ref -p` → else status **BAD** (a file that
  fails to parse on both sides would otherwise "pass" mode A). Directive `--! no-parse-check:` opts out.
- Directives: `--! skip:`, `--! modes: A,B`, `--! timeout: N`, `--! args: ...`.
- Auto-SKIP: `tests/corpus/puc54/*` using `T.*` (PUC ltests hooks): all, api, code, coroutine,
  cstack, errors, events, gc, gengc, locals, nextvar, strings.
- Reports: `tests/report/last.json` + `last.md` (gitignore these).
- known-bad: `tests/known-bad.tsv` = `test<TAB>modes(A/B/R/*)<TAB>reason`; XFAIL/XPASS semantics.

## d54 corpus (20 files, written)
numeric_01_types, numeric_02_arith, numeric_03_idiv, numeric_04_mod, bits_01_ops,
bits_02_metamethods, meta_01_matrix, meta_02_compare_len, lex_01_literals, fmt_01_format,
str_02_pack, utf8_01_lib, tbl_01_lib, goto_01_labels, coro_01_close, gc_01_tbc_gc,
err_01_xpcall, math_os_01, dump_str_01, env_01_fenv.
Convention: tests **print** behavior (differential), a few `assert()` for invariants.
5.4-only syntax (`//`, bitwise, `<close>`) is isolated in its own files or inside `load([[...]])`
so 5.1-parseable files give real semantic diffs instead of parse errors.

## Baseline (before known-bad was recorded)
`tests/harness.sh --mode all --corpus tests/d54`: PASS 38, FAIL 22 (18×A + 3×R artifacts + ...).
The 3 R failures were wrapper artifacts (assert(loadfile) prepended `dump_reload.lua:30:`) — FIXED
in `tests/lib/dump_reload.lua` (now prints `luajit: <err>` and exits 1 like the standalone host).
Also fixed a real syntax error in `err_01_xpcall.lua` (missing paren) found by the new pre-flight.
**Re-run needed** to confirm R is green and to generate known-bad.

## MISSION corrections verified against PUC 5.4.7 (must go into docs/54port.md + MISSION errata)
1. No underscore digit separators (`1_000` → malformed number). §4.1 wrong.
2. No `0b` binary literals. §4.1 wrong.
3. `table.create` is NOT PUC 5.4 (nil) — LuaJIT extension. §4.2 wrong.
4. `%g`/`tostring` use `%.14g` in 5.4.7, **not** shortest round-trip
   (`tostring(0.1+0.2)` == "0.3", `tostring(1/3)` == "0.33333333333333"). §4.2/§10.3 wrong.
5. Bitwise ops accept floats **with exact integer representation** (`3.0 & 1` == 1);
   error only for e.g. `3.5 & 1` ("number has no integer representation"). §4.1 imprecise.
6. Negative shift counts **reverse direction**, no error (`1 << -1` == 0, `255 >> -2` == 1020);
   `>>` is logical; counts are mod 64. Phase-3 "negative-count error" wrong.
7. int→float does NOT truncate: `9007199254740993+0.0` rounds to nearest;
   int↔float comparison is exact (`9007199254740993 == 2^53` is false). §4.1 claim unsubstantiated.
8. Confirmed correct: `__pairs`/`__ipairs` ignored; `__len` may return any value (2.5, "x");
   `^` always float; int `%` sign of divisor, float `%` floor-mod; `math.mininteger // -1` wraps;
   `math.abs(mininteger)` wraps; `math.max(1,2.0)` → 2.0 float; `string.dump(f,true)` strips;
   `coroutine.close` exists; decimal literal overflow → float (no wrap).
9. `tostring(-(0/0))` == "-nan" on aarch64 PUC → nan sign is observable; do NOT normalize it away.
10. `os.time{...}` is TZ-dependent → harness forces TZ=UTC.

## Session 2 progress (porting started)

Commits on `main` after M0 (all harness-green, capi 29/29, mode-B fuzz green):
- `95512f79` utf8 library (full 5.4), `\u{XXX}` up to 0x7FFFFFFF incl. surrogates,
  NUL-aware string patterns (MatchState.p_end).
- `3196b466` `%d/%i/%u/%x/%X/%o` require exact integer representation
  (LJ_ERR_NUMNOINT); argument errors resolve library function names via the
  loaded-module search (port of 5.4 pushglobalfuncname/findfield).
- `956f9d5e` goto/label diagnostics match 5.4 exactly (VarInfo.line added).
- `2fd8c417` `<const>` attributives (5.4 shadowing rules), 5.4 token-error
  quoting (`<name>` unquoted). `<close>` parses but is rejected pending P1.5.
- `1b639633` **int/float split**: scanner no longer narrows integral doubles;
  parser keeps float constants in a dedicated bit-pattern-keyed table (`ktf`)
  so 3 vs 3.0 vs -0.0 stay distinct; foldarith only narrows int-op-int and
  never for `/` or `^`; JIT recorder no longer narrows float constants to KINT;
  5.4 `.0` suffix for float rendering in tostring/concat/table.concat (interp
  + JIT + lj_buf_put); math.type/tointeger/ult added.
- `481da8c6` gmatch 5.4 lastmatch rule; error(obj) keeps non-string objects.

Current d54 status: PASS 48, XFAIL 20, FAIL 0 (23 files).
Full corpus: PASS ~90, XFAIL ~39, SKIP 12, TIMEOUT 2, FAIL 0.

### Key gotchas learned
- `lj_strfmt_putfnum` can REALLOCATE the buffer: never keep a `sb->w` pointer
  across it (caused a segfault; use `sbuflen()` offsets).
- LuaJIT's `luaL_openlibs` calls openers with 0 results, so a new library must
  use `LJLIB_MODULE_x` + `LJLIB_CF` + `LJ_LIB_REG`, not `luaL_newlib`.
- `lj_strscan_scan` returns an UNTAGGED payload; callers must `setitype`.
- The parser's constant table is keyed by number, so integral doubles collide
  with ints — hence the separate float table.
- `-bl`/`-jv` report "jit.* modules not installed" in this build; use direct
  experiments instead of bytecode dumps.

### Still blocked on ADR-001 (int64 value model)
math.maxinteger/mininteger, int64 bitwise semantics (mod-64 shifts, logical
`>>`, negative counts), `//` (needs a new BC op + VM), exact large-int
arithmetic/compare, `tonumber` of large ints, 5.4 dump format.

### MISSION errata additions
- M1 acceptance says "string.dump round-trips with PUC-Lua (normalized)".
  LuaJIT's bytecode is structurally different from PUC's; full PUC bytecode
  compatibility would mean rewriting the VM. Interpreted as: dump/reload must
  round-trip within our own binary (mode R), which is what the harness checks.
- LuaJIT 2.1 accepts `_` digit separators as an extension (5.4 rejects them).
  Kept per MISSION §3 (extensions win); recorded as an intentional deviation.

## Phase 0 deliverable status (session 1)
DONE:
1. Harness (A/B/R) + pre-flight + known-bad + reports; full-corpus baseline recorded.
2. `tests/d54/` 20 files; `tests/corpus/puc54/` vendored; `tests/README.md`.
3. Fuzzers `tests/fuzz/gen.py` + `fuzz.py`; smoke 240/240 mode-B green (opt 0-3, GC),
   0 invalid programs; mode A 15/15 fail as expected on unported 2.1.
4. `tests/ci-local.sh` + `.github/workflows/ci.yml` (x64, x64-sanitizers, arm64, win-build).
5. ASan+UBSan build works and harness is green under it (d54 corpus, no ASan/UBSan reports).
   **Gotcha:** `HOST_CC` defaults to `$(CC)` in src/Makefile, so passing sanitizer flags
   via CC also instruments host `buildvm`, whose intentional leaks abort the build under
   LSan. Fix: `HOST_CC=gcc` + `ASAN_OPTIONS=detect_leaks=0` for the build; target uses
   `-DLUAJIT_USE_SYSMALLOC` (bundled allocator hides overflows from ASan).
   Sanitizer tree lives in `tests/ref/sanbuild/` (gitignored), binary `src/luajit` there.
6. `docs/54port.md` (§4 -> test map + errata), `docs/phase0-status.md` (this file).
7. Commits pushed to the bare origin: base `63c8f1a9` -> `03031827` (harness+corpus)
   -> `12bdf979` (fuzz/CI/sanitizers/docs). Build artifacts were accidentally committed
   once and removed via amend + force-push + gc; `.gitignore` now covers
   `tests/ref/{bin,src,sanbuild}`, `tests/report`, `tests/fuzz/{out,failures}`, `__pycache__`.

OPEN / next:
- Triage `tests/known-bad.tsv` reasons by root cause (feeds Phase 1 task ordering).
- `tests/corpus/puc54/closure.lua` fails **mode B** on unported 2.1 (JIT vs interpreter):
  triage — real LuaJIT 2.1 bug, upstream-suite assumption, or timeout artifact.
- `calls.lua` B/R and `heavy.lua` exceed 60 s per side -> TIMEOUT (inconclusive).
  Either raise the limit for those files (`--! timeout:`) or split them.
- Full-corpus run under ASan/UBSan (only d54 done so far).
- Persist decisions to mneme (`sic hertz lmcp-tool mneme command=remember ...`).
- M0 sign-off, then Phase 1 (lexer -> parser -> bytecode -> interpreter -> C API).

## Blocking-command discipline
Long runs: `nohup ... > /tmp/log 2>&1 &` then poll, or `timeout N`. Full harness run
with `--timeout 60` takes ~2 min wall (calls.lua/heavy.lua dominate). Sanitizer build
~1 min. Never run two harness invocations concurrently (they share tests/report/).
