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

## Remaining Phase 0 TODO (in priority order)
1. Re-run `tests/harness.sh --mode all` (full corpus incl. puc54) → generate
   `tests/known-bad.tsv` via `--update-known-bad`, then curate reasons.
2. Fuzzers: `tests/fuzz/gen.py` (seeded, valid 5.4 programs: numeric/bitwise/metamethod/GC modes),
   `tests/fuzz/fuzz.py` (differential driver A/B/R, saves failing seed+program to
   `tests/fuzz/failures/`, reproducible), `tests/fuzz/README.md`. Smoke run (few hundred programs).
3. `tests/ci-local.sh` (normal + ASan/UBSan build: `make CC=... XCFLAGS=-DLUAJIT_USE_SYSMALLOC`,
   `ASAN_OPTIONS=detect_leaks=0` initially) and `.github/workflows/ci.yml`
   (x64 linux, x64 sanitizers, arm64 linux, windows x64 build check). CI dormant until a real remote.
4. `docs/54port.md` (§4 checklist → test refs), `docs/phase0-baseline.md` (numbers, deviations,
   MISSION errata above), `tests/README.md`, `tests/corpus/puc54/README.md` (provenance/license).
5. `.gitignore`: add `tests/ref/bin/`, `tests/ref/src/`, `tests/report/`, `tests/fuzz/out/`,
   `tests/fuzz/failures/` (keep committed seeds separately), `*.tar.gz`.
6. Commit MISSION.md + Phase 0 (labeled commit `Phase 0 (M0): ...`), `git push -u origin main`.
7. M0 acceptance: harness runs, corpus fails as expected (known-bad recorded), ASan build clean.
8. Optional: persist decisions to mneme (`sic hertz lmcp-tool mneme command=remember ...`).
