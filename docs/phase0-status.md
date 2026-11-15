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

## Session 7 — REQUIRED WORKFLOW CHANGE (external guard) + amd64 box

An external guard now REFUSES local builds: `make` on pica prints
"make is not allowed on this host (dcw2). Run: bash -lc \"dirac-gate build\"" and
exits 97 (wrapper at ~/.local/bin/make; comment cites Markus "Do not build
locally"). So **nothing may be compiled or tested on pica any more**. All
verification must go to the boxes:
- `arm-box` = escher, aarch64 (works; proven this session)
- `build-box` = `build@born.fritz.box`, **x86_64** (new from outside; restricted
  key that only runs build-box). Currently blocked: a card measurement window
  on dirac (`~/wp/window.lock`, started 08:31 UTC, ~80 min) -> exit 75 "try
  later". Re-run after ~09:51 UTC.
- Both copy the tree (no .git) into a fresh dir, run, delete; only stdout comes
  back. Memory cap 8G. Keep jobs small.
Consequence: verify with `arm-box -t 1200 sh tests/ci-box.sh` (or `build-box …`).
`tests/ci-box.sh` + vendored `tests/ref/dist/lua-5.4.7.tar.gz` make that
self-contained and offline-capable (commit `50dee122`).
Also note: `~/.gitconfig` lost user.name/user.email during this session; this
repo sets the identity locally now.

## Session 6 — sanitizer build state (IMPORTANT)

- Fixed a latent parallel-build race: `src/Makefile` now has
  `$(LJLIB_O): lj_libdef.h` (clean -j builds could compile lib_*.c before the
  generated header existed; exposed by adding lib_utf8.c).
- `-DLUAJIT_USE_SYSMALLOC` + ASan on arm64/GC64 CANNOT START: "cannot create
  state: not enough memory" (system allocator returns addresses outside
  LuaJIT's 47-bit GC range). ci-local.sh now sanitizes WITHOUT SYSMALLOC and
  probes the binary before running the harness. Consequence: ASan cannot see
  heap overflows inside LuaJIT's own allocator (stack/global/UB still covered).
  Tracked for Phase 6 (needs a low-address allocator hint).
- UBSan findings (pre-existing LuaJIT UB, NOT introduced by the port):
  * lj_buf.c:298 `(*w & 0x7f) << 28` signed overflow -> FIXED (uint32_t cast).
  * lj_asm_arm64.h:741 `irt_toitype << 47` signed overflow -> FIXED (uint64_t).
  * lj_parse.c:1177 `setgcref(ls->vstack[vtop].name, ...)` misaligned GCobj
    access -> OPEN. Investigate VarInfo layout/alignment (a BCLine field was
    added to VarInfo for 5.4 label diagnostics; check sizeof/alignment).
  Because UBSan writes reports to stderr, the sanitizer harness run shows
  FAILs until these are resolved. Sanitizer-green is therefore an OPEN task.

## Session 5 (in progress) — __len/__pairs + __name type names

DONE (uncommitted): enabled the LJ_52-gated VM paths for 5.4 in ALL 7 backends
(vm_arm64/x64/x86/arm/ppc/mips/mips64.dasc): BC_LEN metatable check + nomm
label, vmeta_len save/NULL-retry, and the `pairs` fast-function metatable
fallback. NOTE: DynASM never receives -D LJ_52, so those gates were always off;
changed to `#if 1`. ipairs gates deliberately LEFT OFF (5.4 ignores __ipairs).
C side: lj_meta.c lj_meta_len (no LJ_52 gate, mmcall passes o twice),
lib_base.c ffh_pairs honors MM_pairs only (+cdata), lj_err.c err_typename()
uses the metatable __name field (5.4 luaT_objtypename).
Verified on arm64: #t with __len returns any value; __pairs honored; __ipairs
ignored; JIT hot loops agree. Only ppc/mips/x86/arm assembly is UNTESTED locally.
New test tests/d54/meta_03_len_pairs.lua. d54 PASS 70, 1 FAIL (meta_03 A) --
CHECK THE REMAINING DIFF (was the FILE* vs userdata type name; __name added).

NEXT: fix the last meta_03 diff, run capi+fuzz+full corpus, commit+push.
Then: MISSION errata (__pairs DOES exist in 5.4.7), final docs/report.

## Session 4 (in progress) — __len on tables + __pairs

GOAL: make `#t` honor `__len` on TABLES (returning ANY value) and make `pairs()`
honor `__pairs`, both matching PUC 5.4.7. Verified by probe:
- PUC: `#setmetatable({},{__len=function() return 2.5 end})` -> 2.5; `"x"` -> "x".
  LuaJIT: both -> 0 (metatable ignored for tables unless LJ_52).
- PUC honors `__pairs` (probe gave 0 iterations); LuaJIT ignores it (2).
  NOTE: MISSION 4.2 claim "__pairs/__ipairs do not exist" is WRONG for 5.4.7 --
  __pairs IS honored. Record as errata. Check __ipairs separately.
- Float `%` ALREADY matches PUC (floor-mod); numeric_04_mod.lua only fails
  because the test file itself uses `//` (parse error) -- fix the test.
- meta_02_compare_len.lua aborts early on math.maxinteger (nil); split the
  __len/__pairs part into its own test.

WHERE: gates are `#if LJ_52` in lib_base.c (lines ~86/91, 227, 608) and
`lj_meta.c:lj_meta_len` (uses LJ_52 for the nomm cache and the mmcall arg).
The VM's BC_LEN also has `#if LJ_52` metatable checks in vm_*.dasc -- changing
those needs care (assembly). Prefer enabling the C paths; check whether the
VM fast path bypasses __len for tables when LJ_52 is off.
`LJ_52` is set by LUAJIT_ENABLE_LUA52COMPAT (lj_arch.h ~731).

DONE THIS SESSION (committed+pushed): P1.3b table borders + rawlen (70501d91),
lua_rotate + capi 34/34. Full corpus PASS 112, XFAIL 36, FAIL 0.

## Session 3 — DONE: table borders (P1.3b) + rawlen

Committed `70501d91`. Two cooperating fixes:
- `lj_parse.c:expr_table` normalizes the constructor template with
  `lj_tab_resize(fs->L, t, narr, hsize2hbits(nhash))` when `t && narr > 1`
  (unconditional-on-asize: keys can sit in the hash even when asize is big).
- `lj_tab.c:lj_tab_len` adds PUC's case-1 fast path: last array slot nil but
  second-to-last present -> return hi-1.
- `lib_base.c` gains 5.4 `rawlen`.
FIXED: the mode-R dump/reload border inconsistency. `#{1,nil,3}` == 3 like PUC.
Remaining divergence is IMPLEMENTATION-DEFINED (runtime-built sparse tables:
any border is legal per 5.4 manual 3.4.7) -> recorded in
`tests/d54/tbl_03_border_divergence.lua`, known-bad, NOT hidden.
d54: PASS 68, XFAIL 19, FAIL 0 (29 files). capi 29/29. Mode-B fuzz 320/320.

NEXT: C API additions (P1.6): lua_arith, lua_getiuservalue/lua_setiuservalue,
lua_newuserdatauv, lua_warning, lua_gc 5.4 actions, luaL_checkversion.
Extend tests/capi/test_capi.c for each. Then package/require (blocked on `//`).

## Session 3 (in progress) — table borders (P1.3b)

GOAL RIGHT NOW: finish the `#` border fix in `src/lj_tab.c:lj_tab_len`.
- Root cause found by instrumenting the parser: for `{1,nil,3}` the template
  table already has ALL positional keys in the array (asize=5, trailing nil at
  slot 4). `lj_tab_len`'s binary search then returned 1 instead of PUC's 3.
- Fix applied (NOT yet built/tested): add PUC `luaH_getn` case-1 fast path —
  if the last array slot is nil but the second-to-last is present, return hi-1.
  A previous attempt ("scan down to last non-nil") was WRONG: it gave 3 for
  runtime-built `t={} t[1]=1 t[3]=3` where PUC gives 1. Reverted.
- The parser-side `lj_tab_resize` experiment was REMOVED (unnecessary), and the
  temporary `#include <stdio.h>` + fprintf diagnostics were REMOVED from
  lj_parse.c. Verify lj_parse.c is clean (`git diff src/lj_parse.c` should show
  only the earlier ktf/const_num/foldarith/attrib changes).
- New test `tests/d54/tbl_02_border.lua` (constructors, runtime tables, holes,
  hash spillover, JIT hot loops). Last run: only diff was `runtime | 1 vs 3`.
- `tests/d54/tbl_01_lib.lua` became XPASS in A and R -> REMOVE its known-bad
  entry once the border fix is confirmed.
- Also still XPASS/pending: none other known.

NEXT STEPS after the border fix:
1. `make -j8`, run `tests/harness.sh --mode all --filter tbl_0 --verbose`,
   then full d54 + `tests/capi/run.sh` + mode-B fuzz, then full corpus.
2. Remove `tests/d54/tbl_01_lib.lua` from tests/known-bad.tsv; add
   `tbl_02_border.lua` only if it still differs.
3. Commit (label `Phase 1 (P1.3b): ...`) and `git push origin main`.
4. Remaining feasible work: C API additions (lua_arith, lua_getiuservalue,
   lua_setiuservalue, lua_newuserdatauv, lua_warning, lua_gc 5.4 actions),
   package/require 5.4 (blocked: upstream attrib.lua needs `//`).
5. BLOCKED on ADR-001 (int64 value model): `//`, int64 bitwise, math.maxinteger,
   large-int arithmetic, 5.4 dump format. BLOCKED on VM work: `<close>`,
   coroutine.close, generational GC, table __gc finalizers, _ENV.
6. Known cosmetic bug P1.8b: tail-call error names (err_02_tailname.lua).

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
