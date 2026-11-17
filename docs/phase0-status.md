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

## Session 9 — step 2b in progress: boxed int64 literal constants

Both boxes were green after steps 2-3 (x64 fix committed `548242a3`: jump to
`vmeta_arith_vvo` after `movzx RAd, PC_RA`; mixed float/int `//` routed to the
C helper; NaN sign documented as implementation-defined and canonicalised
inside the test only).

Benchmark gate ran (arm-box, four arms) BEFORE 2b: b1/b2 fail with
"number has no integer representation" because integer literals beyond int32
are still floats. Measured meanwhile: b3 int32 control ours JIT 46.5 ms vs
stock 38.1 vs PUC 264; b2b (~2^41) ours 143 ms/8 MB, stock(float) 127.8, PUC 172
-- b2b was NOT honest (values came from a float literal, not boxes).

IN PROGRESS (edits applied, NOT yet compiled):
- `lj_bc.h`: new `_(KI64, dst, ___, cdata, ___)` after KCDATA.
- `lj_lex.c` lex_number: STRSCAN_I64/U64 now create a boxed integer via
  `lj_i64_box` (extern decl inside the function is ugly -> move to include
  lj_i64.h). Boxes are rooted in the registry intern table, so holding one in
  the lexer token is GC-safe.
- `lj_parse.c`: big integer literals use the VKCDATA kind (not foldable) and
  emit BC_KI64 with const_gc(..., LJ_TUDATA) instead of KCDATA.
- STILL TO DO: BC_KI64 VM cases arm64 + x64 (copy the 8-byte TValue from
  KBASE+~kidx to BASE+RA*8 UNCHANGED -- do not settp, His's hint), and the dump
  format: `bcwrite_kgc`/`bcread_kgc` assert only STR/TAB/cdata/proto, so a
  udata constant breaks string.dump; add a BCDUMP_KGC_I64BOX tag writing the
  int64 bits and reading them back through lj_i64_box.
- Then: literals test (`lex_01_literals` mode A), full gates both boxes,
  benchmark gate again (now honest), commit per step.

## Session 10 — step 2b done; benchmark gate measured (honest)

Committed `425eaedb` (boxed int64 literals + BC_KI64 + BCDUMP_KGC_I64BOX).
Both boxes green (47/128/32).

Benchmark gate on arm-box with the real int64 model (`tests/bench/run.sh`,
median of 3, four arms):
  b1 FNV-1a-64 (10 MiB):   ours JIT 16463 ms | ours -joff 16422 | stock FFI 15.1 | PUC 278.1
  b2 1e6 64-bit table:     FAILED "attempt to compare two userdata values"
  b2b 1e6 ~2^41 values:    FAILED same
  b3 int32 control:        ours JIT 48.1 | ours -joff 5557 | stock 46.2 | PUC 262.1
=> b1 is ~1000x the FFI yardstick and 59x slower than PUC: every 64-bit op
   allocates+interns a box and the recorder aborts (NYI), so nothing is
   compiled. b3 shows no JIT regression (48.1 vs 46.2), interpreter 5557 vs
   the earlier 372 because int32 mul overflow now boxes.
   b2/b2b blocked by missing box<->box comparison.

NEXT (in this turn): add box-aware compare in lj_meta_comp (and lj_obj_equal
already covers interned equality) so b2/b2b run; rerun bench; write the table
into docs/adr-001b-boxed-i64.md; then Markus decides on step 5/47-bit with the
numbers.

## Session 11 — Markus decided the post-benchmark order (steps 1-3)

Order (gate both boxes + bench table after EACH step, commit per step):
1) dedicated int64 intern hash (open addressing keyed by value, weak entries
   swept by GC like strings) -> target B2 memory ~16-32 B/value.
2) 47-bit inline integers on GC64 (fast path + overflow checks int32 -> signed
   47-bit; non-GC64 stays int32; VM per backend arm64 then x64; JIT int guards)
   -> target B2b with no boxes, B3 no regression. This is ADR-001b step 6.
3) step 5: IRT_I64 + allocation sinking reusing the FFI int64 machinery
   (lj_crecord/lj_opt_sink) -> target B1 within ~1.5x of stock FFI.

Step 1 design chosen (cheapest that gives real sweep hooks, WITHOUT a new GC
tag -- a new tag would also have to shift LJ_TNUMX and only tags with bit 0 = 0
encode consistently, so NUMX must stay odd):
- Keep boxes as GCudata with UDTYPE_I64BOX.
- Add an open-addressing hash (GCRef tab, mask, num) to global_State, appended
  at the END (GG_* offsets used by the assembler stay valid).
- Key = int64 value, mixed; probe linearly; NULL ref = empty; tombstones for
  deletions (sentinel pointer) or backward-shift deletion.
- lj_i64_box(): probe hash, return existing box, else allocate the udata and
  insert; grow/rehash at ~75% load.
- Sweep: in lj_gc.c's sweep loop, before freeing a GCudata whose udtype is
  UDTYPE_I64BOX, call lj_i64_remove(g, ud). Otherwise freed boxes would stay
  reachable in the hash (use-after-free).
- Free the hash table on state close next to where g->str.tab is freed.
Bundled with this step: the B2/B2b/B1 benchmark rerun and the ADR table.

## Session 12 (compaction point) — resume instructions for step 2

State: order step 1 done (`fbfc4886`). Step 6 sub-step 1 done (`bab4faad`):
47-bit primitives exist (lj_obj.h: LJ_I47_MIN/MAX, i47_fits, setint47V,
intV47, tvisi47w), lj_i64_getint reads widened, formatting + numeric coercion
use exact values. NO widened value is stored yet, so the tree is green.

RESUME ORDER (do NOT activate widening before 1 and 2 are in):
1. VM checkint gains a range test (header arm64 first, then x64): payload bits
   32..46 must be the sign extension of bit 31 (it low 15 bits == 0 or 0x7fff).
   Widened operand or overflow -> route to lj_i64_arith / lj_meta_bitop /
   lj_meta_arith, never the 32-bit asm path.
2. lj_tab: widened integer keys need a 64-bit path (lj_tab_getint64 /
   setint64; hash key encoding must not truncate; Node key compare exact).
3. ACTIVATION: lj_i64_store stores widened inline (setint47V) when the result
   fits 47 bits instead of int32-or-box; also let arithmetic results go inline.
4. JIT recorder: NYI for tvisi47w (recorder currently rejects boxes; add the
   widened predicate in sload/constify as well).
5. Gate both boxes (`arm-box -t 1200 sh tests/ci-box.sh`, `build-box ...`) and
   bench (`arm-box -t 1800 sh tests/bench/run.sh`); targets: B2b no boxes,
   B3 no regression.
Then step 3 (IRT_I64 + sinking, target B1 <= 1.5x stock FFI).
Full audit list and encoding derivation: docs/adr-001b-boxed-i64.md.

## Session 13 — step 6 activation attempt found a bug; left DISABLED

Kept (inert, green): VM checkint range test (arm64 ubfx+cbnz, x64 mov/shr/and/
jnz), lj_tab widened-key normalisation (widened int key -> exact float key,
passthrough in lj_tab_get/set/keyindex), lua_tointegerx reads widened.
Activation (lj_i64_store storing setint47V) is wrapped in `#if 0` with a
comment: with it on, `local y = (1<<40) + (1<<32) print(y)` printed **257** --
the payload's high field -- while `x==y`, `x<y`, `math.type(y)` and compare
paths were correct. Reproduce on a FRESH box (make clean; always rebuild -- a
copied stale src/luajit otherwise runs) and bisect: likely a consumer that
prints the high field (check lj_strfmt_number vs wstrnum branch), or an
encoding read path (intV47) confusion. Fix, then enable, then gate both boxes
+ bench (targets B2b no boxes, B3 no regression), commit, send claude.

## Session 14 — widened getint/tab fixes landed; activation still OFF

Fixed and kept: `lj_i64_getint` checks tvisi47w BEFORE plain int32 (it was
truncating widened values to their low word — the 257/0 symptom); lj_tab_get/
set declare `TValue tmp` at function scope so a normalised key outlives the
branch (dangling pointer previously); lj_meta_comp treats widened operands as
numeric comparisons. Boxed-int64 *keys* stay pointer keys (an attempted
exact-double normalisation crashed; documented limitation: box key != float
key for exact values, 5.4 divergence to fix later).
Activation (lj_i64_store storing setint47V) is again `#if 0`: with it on,
B1/B2 checksums were wrong (-4587520 vs 343592796160) while b2b improved to
278.8 ms / 79 MB. So one op path still truncates a widened value; bisect with
`tests/bench/b1_fnv.lua` (FNV = xor + multiply loop) -- check BC_BSHL/BSHR
vmeta route, BC_BAND/BOR/BXOR asm checkint route, mul/add overflow route, and
`lj_meta_cat`/for-loop setup (`lj_meta.c:584` intV on widened?).
Arm gate after disabling: FAIL 0, XFAIL 17, i64 OK. x64 gate run hit the box
job timeout (124, inconclusive) -> re-run.

## Session 15 — bisect with activation ON: two findings

Per-op probes with widened operands (a = 1<<40) were correct for xor/and/mul/
add/shl/shr/concat (wrap mod 2^64 for a*a -> 0 is correct 5.4). Wrong:
- **for-loop setup truncates**: `for i=a,a+2 do s=s+i end` returns 3 instead of
  3*a. Cause: `lj_meta.c` for-loop preparation uses intV() on start/stop/step
  (lines ~584-597). Fix: use the exact reader there (intV47 for widened) and
  write the loop slots with setint47V when they fit; FORI only runs for int32
  loop variants in the VM, so widened loop bounds must route to the float/FORN
  path or convert exactly.
- **inline-widened vs boxed equality is false**: `(a ~ 1) == 1099511627776 ~ 1`
  is false because the literal is a boxed constant and one side is inline.
  Equality needs the numeric compare in lj_obj_equal/BC_ISEQ for int-inline vs
  box (both exact), not the pointer/word compare.
These are the candidates for B1's wrong checksum (b1 uses `h ~ byte`, `* prime`,
`+`, `& 0xffff` — all individually correct, so the remaining suspect is an
int-vs-box comparison inside the *fold/guard* path or the 0xffff mask path on
a box).
Activation stays OFF again after the bisect job (tree green).

## Session 16 — for-loop and inline-vs-box equality fixed; FNV checksum still wrong

Fixed and in the tree: `lj_obj_equal` compares a boxed/widened integer against
any number by exact value (5.4); `lj_meta_for` converts widened inline or boxed
int64 loop bounds to exactly-representable floats BEFORE the number checks (a
box previously raised "'for' initial value must be a number"; widened bounds
truncated to their low words, `for i=a,a+2` returned 3 iterations of 3).
Verified: `for` over 1<<40 bounds iterates correctly; `(a~1)==(1099511627776~1)`
true; box arithmetic prints exact.

Still wrong: with activation ON, `tests/bench/b1_fnv.lua` gives checksum
-4587520 instead of 343592796160. All individual ops were correct in probes
(xor/and/mul/add/shl/shr/concat on 1<<40). The FNV loop mixes a *boxed literal*
as the starting h (0xcbf29ce484222325 is a box, literals never become inline)
with widened results: suspects are (a) `h & 0xffff` where h is widened and the
mask path routes via lj_meta_bitop -> check the BC_BAND asm `checkint` target
on both operands, (b) `cs = cs + small` where cs widened, (c) the initial
`h ~ byte` with a box lhs through the FFI-vs-5.4 branch in lj_meta_bitop.
Bisect plan: instrument b1 with a per-iteration `print(h, math.type(h))` for
the first 3 iterations and compare against PUC 5.4.7; then toggle one op at a
time (replace `&`/`+` with explicit helper calls) to isolate.

## Session 17 — decisive result: it is (a), the VM

With activation ON, `tests/bench/b1_fnv.lua` gives checksum -4587520 under
BOTH `-joff` and `-jon` -> the interpreter, not the JIT narrowing. His's
analysis: 343592796160 - (-4587520) = 343597383680 = 80 * 2^32, i.e. the right
sum wrapped at 32 bits.
Root cause candidate (next action): in `vm_arm64.dasc` `ins_arithdn`,
`ins_arithcheck_int >5` sends a *widened* inline integer to label 5, the FP
variant, which loads a NaN-boxed integer value as an IEEE double (garbage) and
stores a float; the int32 asm path is skipped, so the sum never reaches
`lj_i64_arith`. Fix pattern: split the check -- a tag mismatch (float operand)
keeps the FP path; a widened int32-range failure (payload bits 32..46 set) goes
to a new label that calls `lj_i64_arith` with the ORIGINAL operand slots and
continues (no 32-bit store first). Mirror on x64 (add/jo path). Then enable,
gate both boxes (incl. the overdue x64 re-run), bench, commit, send.

## Session 18 — arm64 helper routing landed, but it does NOT fire for a boxed operand

Patched vm_arm64.dasc: new `checkintw` (separate widened target) + label >7/-6
in `ins_arithdn` (ADD/SUB/MUL/MOD) and `ins_arithfp` (DIV/POW) calling
`lj_i64_arith` with the original slots; new `ins_arithfb_i64` for the vk-aware
vmeta fallback. Builds and runs.

Measured (activation ON, widened store ON): B1/B2 still `unsupported`/wrong, and
a *direct* probe disagrees with itself:
  `local mi = math.maxinteger; print(mi+1)` -> -2  (WRONG, int32 low-word add)
whereas `print(math.maxinteger+1)` in one expression -> -9223372036854775808
(correct). So with a box in a *stack slot* the ADDVN check passes the int32
fast path, i.e. the boxed udata's tag word equals `TISNUMhi` (x25). That is
consistent with -2 = low-word add of the udata pointer. Hence `checkint`
(and `checkintw`) never route boxes to the C helper; they must special-case
`tvisudata`/box in asm (or the box tag must differ from the inline NUM tag).

Also observed: `(a~1)==(1099511627776~1)` is false with activation ON though it
was true with it OFF -> the VM `BC_ISEQV` fast path compares raw words, so
lj_obj_equal's exact compare never runs for inline-vs-box; equality needs the
same routing as arithmetic.

Next: (1) print the actual high words for int32-int, widened-int, box, float
from a tiny C patch or a `-e` script with `tostring`+`string.format("%x")` on
internals; (2) fix the tag test accordingly; (3) route BC_ISEQV to
lj_obj_equal when a box is present; (4) then enable, gate both boxes, bench.
Activation back to #if 0 so the tree behaves like the last green gate.

## Session 19 — STEP 2 DONE: 47-bit inline integers enabled, checksums exact

Three real fixes:
1. vm_arm64 `checkintw` + labels >7 (add/sub/mul/mod) and >6 (div/pow) call
   `lj_i64_arith`; the operand loader is vk-aware (case 0/1 use KBASE for the
   constant side -- the first version always used BASE and read a stack slot).
   Operand routing: `cmp TISNUMhi; bhi ->helper` (widened int / GC object) and
   `blo ->FP` (double keeps the fast path).
2. `i64_store`: widened inline only while payload bits 32..46 are nonzero.
   Values in [2^31, 2^32) encode with p=0 and would read back as the signed
   int32 of their low word (measured: 2147549175 came back as -2147418121).
   That narrow band stays boxed.
3. (earlier) exact equality vs any number, for-loop bounds.
Result: b1 = 343592796160 and b2 = 4047905256 on arm64 AND x64 (x64 did not
need the asm patch: its checkint already routes non-int32 to the FP label but
x64's int path evidently widens correctly -- verified by checksum).
Gates: both boxes GREEN (A+B 47 PASS/0 FAIL/17 XFAIL, opt 128, R 32, capi 34,
i64 14/14).
Bench (arm-box, median): ours JIT b1 6858 / b2 2279 / b2b 251 / b3 46.3;
ours -joff 6821 / 2282 / 269 / 3990; stock FFI 15.8 / 819 / 141 / 44.9;
PUC 277 / 543 / 173 / 284. So b2 2.8x and b2b 1.8x vs FFI, b1 434x -- all
values now go through the C helper in the interpreter, which is exactly what
step 3 (IRT_I64 + allocation sinking) has to fix.
OPEN DIVERGENCE: b3_int32 sum differs between ours JIT (1232839951),
ours -joff (1196193376 == PUC) and stock (1303583832): the JIT narrows
int32 arithmetic without the widened/overflow guard. Step-3 scope.

## Session 21 — step 3 blocked on allocation PHIs; step 2 tree restored (a5b97b92)

Step-3 WIP (b99fe41d) is reverted: the IR_BOX model is semantically correct
(`local s=1<<40; for i=1,300 do s=s+1 end` -> 1099511628076) but the trace is
rejected with LJ_TRERR_NYICOAL ("register coalescing too complex") on aarch64,
with and without allocation sinking enabled. Adding the FLOAD(BOX, UDATA_I64)
-> payload fold rule (Claude's item 1) and the gcstep/alloc lists did not fix
it; removing the RID_RET hint for IR_BOX reduced the retries (5 -> 3) but the
trace still fails. So a loop-carried int64 box PHI (allocation-type PHI) does
not assemble in this tree as it stands, and the alternative raw IRT_I64 PHI
restores a wrong register value at exits.
State now: step 2 (47-bit inline enabled) is green on both boxes again; gates
47 PASS / 0 FAIL / 17 XFAIL, opt 128, R 32, i64 14/14. Bench unchanged from
e4fad1a4. The step-3 target (B1 <=1.5x stock FFI) remains out of reach until
the PHI/allocator issue is solved; b99fe41d holds the full WIP for resume.

## Session 22 — coroutine.close landed; <close> needs per-scope close state (parked)

Landed and committed (12f39869): coroutine.close (5.4: suspended reset, dead
with error -> false + error object, running/normal -> "cannot close a ..."
error) and coroutine.running() now returns (thread, ismain) as 5.4 requires.

<close> WIP analysed and reverted: parser accepts `<close>`, GCproto carries a
per-function slot list (declaration order computed in FuncState, appended after
varinfo, `sizetbc`), and VM UCLO calls `lj_tbc_close(L, level)` which runs the
__close metamethod (new MM_close at the END of MMDEF so no arith ids shift;
normal exit passes nil). Verified: `do local x <close> = obj end` closes in
reverse declaration order, and `return`/`break` paths close too.
Blocker: a static per-function slot list cannot express per-scope close state.
Entries for inner-block variables stay in the list, slots are reused, and a
sentinel written after a close does not survive slot reuse; the chunk then
raises "variable got a non-closable value" on stale entries. PUC solves this
with compile-time close lists plus runtime slot state (OP_CLOSE). Next attempt
should: keep per-block close lists with a level per block (parse-time), so UCLO
closes only the entries of the blocks being left, matching the level filter;
cover the error-unwinding path in lj_err_run; and keep the sentinel only as a
double-close guard.

## Session 23 — <close> parked again: per-UCLO pc mapping cannot pass PC from the VM

Second attempt: per-block close lists tagged with the UCLO bytecode position
(FuncState records (u16 pcpos, u16 slot) pairs for each emitted UCLO; GCproto
carries them after varinfo and dumps are refused for such functions), plus
MM_close at the END of MMDEF and VM UCLO calling lj_tbc_close(L, level, pc)
before closing upvalues. Parser bookkeeping (active close stack, per-scope
entry counts, return paths closing all active entries) is in place.
Blocker: the VM keeps PC in an encoded form inside the UCLO handler
(`sub PC, RC, #0x20000` after computing the target), so passing PC as a real
code pointer produces a garbage position and a segfault in the nested
__close call. Also clobbering CARG3 (openupval) broke the upvalue branch.
Next attempt: get the UCLO position without the VM's PC: (a) set SAVE_PC before
the call and let the helper read it, or (b) give UCLO a literal list id
instead of a pc tag (add a bytecode operand or a parallel table keyed by a
pseudo level). Keep the parser bookkeeping and the proto map; only the VM
hand-off needs rework. Error unwinding (lj_err_run) is still not wired.

## Session 24 — <close> third attempt: pc hand-off works; the __close call context blocks

Per-UCLO pc-tagged close lists now work: the VM captures the PC before the
TARGET-encoding `sub PC, RC, #0x20000` (arm64) / before `branchPC` (x64); the C
helper computes pos = pc - proto_bc(pt), and the recorded pairs match at
pos == pair+1 (PC is "next PC"). Verified with a print-only stub: slots and
pairs matched for scope exits, returns and break. Cancelling the real call
crashes: invoking `__close` through `lua_call` from the UCLO C helper has no
proper C frame (lua_call expects a cframe context; the VM opcode handler is not
one). Options for the next attempt:
(a) VM-side metamethod continuation: UCLO sets up the metamethod call like
    vmeta_binop and continues at cont_nop, closing one variable per iteration
    (state kept in a list index passed through L->top?),
(b) parser-emitted close calls: a bytecode sequence that calls __close through
    the normal call machinery, which needs a way to fetch the metamethod,
(c) a C-side call with an explicitly constructed cframe (research whether
    lj_vm_call accepts a synthetic FRAME_CP).
The parser bookkeeping (active close stack, per-scope entry counts, return
paths, proto pair map, dump refusal) is reverted again and ready to re-apply
from this note. No new design question for Markus: (a) is the least invasive.

## Session 25 — <close> fourth attempt: pc hand-off + cpcall run, but two defects

New since session 24: the UCLO C helper invokes __close inside `lua_cpcall`
(a real C frame, so lua_call is legal), level is passed as an integer (the
TValue* hand-off was garbage), and the x64 call args respect the POSIX ABI
aliases (CARG1=rdi, CARG2=rsi, CARG3=rdx=BASE; PC is rbx, callee-save; capture
the UCLO pc in TMPR before branchPC).
Measured working: reverse-order close at scope exit (`c,b,a` with nil error
args), close before return, nested inner-first order, `math.fmod/abs` style
plain pop, and direct returns all call __close.
Defects:
1. Inside such a __close, an upvalue captured by the metatable closure reads as
   the wrong type ("attempt to concatenate upvalue 'tag' (a table value)" in the
   test), so a cpcall from the UCLO helper corrupts closure upvalues. This is
   the blocker for enabling the feature.
2. break/goto converted to UCLO by parser fixups do not match the recorded pc
   pairs; a pass-2 fallback (close every active slot >= level, sentinel prevents
   doubles) closed the break case but likely contributes to (1), and the
   slot-reuse risk stays.
Error-path closes (error in the body) are still not wired; nil to-be-closed
values are skipped instead of erroring at declaration.
Next: isolate (1) with a minimal cpcall+upvalue C test (probably L->top/frame
placement inside the UCLO handler), then choose between cpcall and a VM-side
metamethod continuation; keep the parser/proto map and both VM hooks.
## Session 26 (branch step3-i64, merged as merge-step3) — STEP 3 LANDED: int64 in the JIT

Design and measurements: docs/adr-001b-boxed-i64.md, "Step 3 implementation".
Summary: a 5.4 integer outside int32 is a raw IRT_I64 register value in a
trace; an IRT_INT ref is always an int32 inline TValue; results that fit int32
are narrowed under a guard where they are produced, so a slot's IR type follows
the interpreter's representation and never changes inside a trace. SLOAD gets
an IRSLOAD_I64 mode whose single guard accepts widened inline and boxed
values. Trace tails store int64 slots through lj_i64_tvstore (C) and drop them
from the final snapshot. Loop PHIs int<->int64 are fixed like int<->num.
Not recorded yet (NYI aborts): int64 table values/keys, int64 upvalues, fast
functions with int64 arguments, int64 vs float compares, //.

Interpreter bugs the new tests/d54/i64_02_jit.lua exposed and fixed: parser
negated boxed literals in place (corrupting the intern table), lexer boxed hex
literals that wrap into int32, BC_UNM on both VMs (floats for -0 and -(-2^31),
low-word negate of widened), BC_ISEQV/ISEQN on both VMs (low-word or raw-word
compare for widened/boxed values), mixed int64/float arithmetic read the low
word of a widened operand.

Rule for the future: a box never holds an int32-range value (canonical
encoding); every producer must go through lj_i64_toTValue/lj_i64_tvstore.

## Session 27 (branch close-tbc) — <close> / __close LANDED on arm64 + x64

Design (fifth attempt; the previous four are above): no C-side call from the
UCLO handler at all.
- Runtime list per thread (`L->tbclist`, stack offsets, innermost last). New
  `BC_TBC A` registers slot A at the declaration (nil/false ignored, a value
  without __close errors with the variable name). The parser marks a scope
  with <close> variables like a scope with upvalues, so the existing UCLO is
  emitted at every exit (block end, break/goto via gola_close, return via
  `fs->ntbc`); `return f()` in such a scope is not a tail call (5.4).
- UCLO pops ONE pending slot at or above its level, builds an ordinary
  metamethod call frame `__close(value, nil)` with the new continuation
  `lj_cont_tbc`, whose return PC is the UCLO itself: the VM re-executes the
  UCLO until nothing is pending, then closes upvalues and jumps. MULTRES is
  parked in an extra slot below the continuation and restored by the
  continuation (CALLM + UCLO + RETM).
- Error path: `err_unwind` runs the pending handlers once the catching frame
  is known (pcall(), lua_pcall, lua_cpcall, C frames with a catcher below),
  with L->top still above the discarded frames and the catching frame as the
  caller (PUC order; an error in a handler replaces the error object). A
  dying coroutine keeps its variables; `coroutine.close` runs them with the
  error object; `coroutine.wrap` closes before propagating an error.
- Generic for: the 4th (closing) value lives in a hidden slot below the
  iterator triple; `BC_TBCCLO` at the loop-exit label closes it (break and
  fall-through); the recorder specialises BC_TBC/BC_TBCCLO on nil/false so
  pairs/ipairs loops still compile. Functions with explicit <close>
  variables stay in the interpreter (UCLO aborts recording).
Tests: close_01_semantics, close_02_paths (new), close_03_puc_locals (the
<close> sections of PUC's locals.lua, verbatim) in mode A (vs PUC) and B.
Also: io file handles get __close (io.lines' 4th return value is the file),
5.4 traceback wording "in metamethod 'close'", "cannot resume non-suspended
coroutine". Documented divergences: inside a __close handler on the error
path, level 2 is the unwound Lua function (PUC: the pcall C function); a
yield from such a handler crosses the C-level protected call (PUC resumes it).
Gates at aa4ab2cd (close-tbc, includes main d7da0bd2), both arches identical:
A+B 71 PASS / 0 FAIL / 13 XFAIL / 0 XPASS, opt 0-3 164 PASS (+4 XFAIL
math_os_01 B from main), R 42, C API + i64 14/14, fuzz 160/160.
Bench unchanged: arm64 B1 13.7 ms (FFI 8.9 this run, 15.2 the run before),
B3 22.9 / 214 ms; x64 B1 30.2 (FFI 29.3), B3 52.3 / 1564 ms; checksums equal.

## Session 26 (DeepSeek, main) — P5 library exactness batch; C API 5.4 WIP awaiting review

Landed (all gates green on x64-box and arm-box; last counts 67 PASS / 0 FAIL /
14 XFAIL, opt 156, R 41, i64 14/14, fuzz 160/160):
- C API integer acceptance: lua_tonumberx/luaL_checknumber/luaL_checkinteger/
  luaL_optinteger accept widened/boxed 5.4 integers; lua_isinteger too.
- io (subagent): 5.4 read formats n/a/l/L, byte-count args, io.lines 4-value
  shape, seek returns the position, setvbuf sizes, input/output(name) opening,
  closed-default messages; tests/d54/io_02_exact.lua PUC-identical.
- package (subagent): package.searchers two-result protocol, require(name,data)
  -> (module,data), loader data (filename / ":preload:"), PUC error
  accumulation, searchpath shapes; tests/d54/pkg_02_searchers.lua PUC-identical;
  corpus attrib.lua now passes.
- string patterns (subagent): gsub lastmatch/empty-match/changed-tracking, %0,
  %%, replacement errors, gmatch init, invalid-capture-index and %b wording;
  tests/d54/str_03_patterns.lua PUC-identical; pm.lua matches except its final
  %p identity assert (interning, needs lj_str.c).
- os.date/os.time: PUC getfield rules (non-integer/out-of-bound errors, deltas),
  os.time normalises and rewrites the table, "cannot be represented" errors;
  tests/d54/os_02_date_time.lua PUC-identical.

WIP (UNCOMMITTED, awaiting review): C API 5.4 additions by a coder subagent —
lua_newuserdatauv (nuvalue 0/1; >1 errors), lua_getiuservalue/
lua_setiuservalue (single user value in GCudata.env, unused2 bit flags),
lua_warning + Lua warn() builtin (registry `_LJ_WARN_ENABLED`/
`_LJ_WARN_BUILTIN`, default ON — a policy divergence from PUC auxlib),
lua_setcstacklimit no-op returning 0, luaL_addgsub/buffsub/pushfail,
lua_getfenv/setfenv adapted for UDTYPE_USERDATA; 69 capi checks. A read-only
reviewer is running over the diff; apply its fixes before committing.
Known limitations reported there: userdata user-values >1 need a GC layout
change; non-GC user values cannot be stored in the GCRef slot; lua_resume keeps
the LuaJIT signature; debug.getuservalue still assumes a table env.

Merge gate: His will announce merge-step3 (branch step3-i64 from Fable). Then
`git merge --ff-only origin/merge-step3` and re-run both boxes. Until then stay
away from lj_i64.c/.h, lj_meta.c, ISEQV/ISEQN in vm_arm64/x64 and UCLO/close.

Queue after this: remaining known-bad corpus items (constructs/literals/math/
errors/locals/vararg/strings/sort/debug/files), then C API lua_resume signature
and debug.getuservalue, luaconf default paths (lua/5.4 vs luajit-2.1).

## Session 28 (branch i64-part2) — int64 in the JIT, part 2: tables, upvalues, varargs, //

On top of close-tbc f7362562. Loads of widened/boxed values from tables,
upvalues and varargs are typed IRT_I64 and decoded by the step-3 unified
guard; stores go through `lj_i64_tvstore` behind ordinary ASTORE/HSTORE/
USTORE with TBAR/OBAR; int64 vs float compares via `lj_i64_cmpnum`; `//`
recorded; type/select/assert/pcall/xpcall/rawequal accept int64 arguments.
Two bugs found by the new test and the B2 checksum: (1) the write-barrier
CSE across LOOP (`gcstep_barrier`) did not count an int64 store as an
allocation, so a GC step at the loop head blackened the table and the loop
stored white boxes unbarriered (boxes freed under a live table); (2) x64
`asm_fuseload` fused an IRT_I64 ALOAD as a raw memory operand. Also the x64
interpreter's ISLT family compared only the low words of two widened ints.
Still NYI: int64 table keys. Details and bench tables in
docs/adr-001b-boxed-i64.md "Step 3, part 2".
Gates at 8742442c, both arches identical: A+B 75 PASS / 0 FAIL / 13 XFAIL /
0 XPASS, opt 0-3 172 PASS (+4 XFAIL math_os_01 B), R 44, C API + i64 14/14,
fuzz 160/160.
Bench (JIT arm, median of 3): arm64 B1 14.9 ms (FFI 15.2), B2 1358.6 ms /
79 MB (was 2279.7 / 522 MB; FFI 719, PUC 598), B2b 148.1 ms (was 270; FFI
139.7, PUC 176.8), B3 22.2 / 226.4 ms; x64 B1 30.4 (FFI 29.2), B2 3405.9 (was
7327.7; FFI 2589.7, PUC 2151.5), B2b 675.4 (was 1135.4; FFI 612.6, PUC
729.7), B3 47.7 / 967.3 ms. Checksums equal (B2 4047905256 now stable).

## Session 27 — C API 5.4 landed after review; main thawed and merged with step 3 + <close>

origin/main fast-forwarded to 18af030f (step 3 int64 JIT, <close>/__close in the
VM, i64 part 2, all library work); this tree was rebased onto it and the C API
work sits on top.

C API (reviewed by a read-only reviewer; blockers fixed):
- lua_newuserdatauv/getiuservalue/setiuservalue: single user value uses
  GCudata.env with unused2 bit0=nuvalue, bit1=value-present; nuvalue 0/1 only,
  >1 aborts with a clear message (GC layout change needed for arrays); non-GC
  user values cannot be stored in the GCRef slot (return 0, documented).
- lua_getfenv returns the table env for nuvalue=0/userdata with no value (no
  mistagged objects); lua_setfenv only marks the value present when the object
  declared one; debug.getuservalue/setuservalue now route through the new APIs.
- lua_warning/warn(): PUC state machine (off/on/continuing) in the registry,
  "Lua warning: " prefix and newline, no dispatch to a Lua warn replacement
  (the old recursion blocker), controls only in the default handler; warn()
  requires at least one string argument and has no boolean tocont; auxlib
  default is warnings OFF like PUC luaL_newstate; lua_setcstacklimit returns
  LUAI_MAXCCALLS (200); lua_getiuservalue checks stack slots.
- luaL_addgsub/buffsub/pushfail added (addgsub guards the empty pattern).
- Not done: lua_resume's 5.4 signature (lua.h + one definition + external call
  sites; in-tree has only the definition), lua_setwarnf/lua_WarnFunction,
  userdata arrays >1. Tests: tests/capi/test_capi.c now 75 checks.

## Session 27b — luaconf default paths = PUC 5.4.7

luaconf.h now targets /lua/5.4 (/usr/local/share/lua/5.4, /usr/local/lib/
lua/5.4) and the LUA_PATH_DEFAULT/LUA_CPATH_DEFAULT ordering matches PUC build
defaults exactly (share, lib/lua, ./, ./?/init.lua; cpath lib/lua/5.4 plus
./?.so), dropping the luajit-2.1 share dir. Bare `luajit -e 'print(package.path,
package.cpath)'` diffs empty against the PUC build. jit.* module lookup now has
no luajit-2.1 default (they were unavailable anyway; MISSION extension note).

## Session 27c — parser: return must be the last statement of a block

`return;;` loaded before (empty statements after return were accepted). A return
now allows exactly one optional `;` and then requires parse_isend (end/else/
elseif/until/eof); the corpus errors.lua line58 case works. This is the Lua 5.4
grammar rule that PUC enforces via luaY_checknext/luaK_return.

## Session 27d — lexer escape-error token text: attempt reverted

PUC's lexerror corpus cases need the consumed escape text in the "near '...'"
token (e.g. \x5"). The lexer builds the *parsed string* in ls->sb, so appending
the escape bytes corrupts valid literals (literals.lua line32 broke). A correct
fix must collect the source chars in a side buffer and append only on the error
path (x: '\\','x',up to two digits + offending char; u: '\\','u','{',digits +
offending char). Reverted to keep the tree green; literals.lua stays known-bad.

## Session 29 (branch i64-keys) — int64 table keys

Integral keys live in the hash part as canonical integers (int32 inline,
widened, box), never as floats: t[2^60] is t[1<<60], next() returns
integers (also for sparse int32 keys, a stock-DUALNUM divergence), float
keys with integral values normalise on get/set but not in next() (PUC
findindex). Hash by value for all encodings (hashi64), lookups decode node
keys, so no box needs to exist for a lookup. JIT: rec_idx_key normalises
under guards and keeps IRT_INT/IRT_I64 keys; asm_href/asm_hrefk on both
arches hash and compare integer keys by value, int64 keys decode the chain;
NEWREF int64 -> lj_tab_seti64. Also: template tables dump int64 keys/values
(BCDUMP_KTAB_I64), weak tables keep boxed integers, lj_i64_box resurrects
a dead box found during the sweep, lj_meta_tset stops floating keys, the
parser constant table keeps its boxed-literal keys. Details and bench
tables: docs/adr-001b-boxed-i64.md "Step 3, part 3".
Gates at 87dfc75e, both arches identical: A+B 81 PASS / 0 FAIL / 13 XFAIL /
0 XPASS, opt 0-3 184 PASS (+4 XFAIL math_os_01 B), R 47, C API + i64 14/14,
fuzz 160/160. Bench unchanged against part 2: arm64 B1 16.5, B2 1520.6, B2b
130.7, B3 23.7 / 212.9 ms; x64 B1 30.2, B2 3124.3, B2b 662.3, B3 47.6 /
955.6 ms; checksums equal.

## Session 27e — lexer escape-error token text (side buffer)

x/u escape parse errors now include the consumed escape source in the "near"
token (PUC lexerror cases); the text is collected in a side buffer and appended
to ls->sb only on the error path, so valid literals stay intact. literals.lua
advances from line32 to its lexerror block (line83, second case still differs);
known-bad.

## Session 27f — generic/decimal lexer escape tokens

Generic invalid escapes (`\g`, `\.`) now reject like PUC and carry the escape
source in the error token; EOF cases no longer append the EOF byte (matches
`lexerror([["abc\x]], [[\x]])` etc.). corpus literals.lua advances to line100
(decimal escape overflow `\999"` needs the trailing source char in the token;
the lexer's sb only holds bytes up to the failure - a look-ahead scan is needed).

## Session 27g — decimal overflow + \u overflow lexer tokens

Decimal overflow (\999, \300, \256) error tokens now include the source up to
the string terminator; \u error tokens include the consumed digits/characters
and too-large is checked before the shift (uint32 wrap used to hide
\u{100000000}). All the literals.lua lexerror cases through the UTF-8 block now
find their "near ..." text; corpus literals.lua advances further.

## Session 27h — fork dump version 0x84

BCDump format changed (KGC_I64BOX inserted before KGC_STR, KTAB_I64 added, 5.4
bytecode), so BCDUMP_VERSION is now 0x84 (>= 0x80, the private fork range).
The reader stays strict: any other version/flags produce the normal "cannot
load malformed bytecode / bad precompiled chunk" error (no crash). Stock LuaJIT
2.1 dumps are rejected instead of misparsed, and stock 2.1 rejects ours.
tests/d54/dump_03_version.lua checks round-trip, a hand-crafted version-2 header
rejection and the >=0x80 version byte; A/B are known-bad (PUC dump format
differs), mode R runs it.

## Session 27i — LUA_PATH_5_4 / LUA_CPATH_5_4 / LUA_INIT_5_4 precedence (PUC 5.4)

luaconf.h defines the versioned env names; package setpath prefers
LUA_PATH_5_4/LUA_CPATH_5_4 over LUA_PATH/LUA_CPATH (PUC lloadlib order), and
luajit.c initialises from LUA_INIT_5_4 before LUA_INIT. Path defaults themselves
were already PUC-identical (session 27b). Gate pending in the next context.

## Session 28 — identifiers are strict Lua 5.4 (deliberate divergence)

Markus decision (2026-11-16): identifiers are ASCII letters/digits/underscore
only; bytes 128-255 are rejected. Stock LuaJIT's lexer accepts them
(lj_char_bits marks 128-255 as IDENT); this fork deliberately follows PUC 5.4
(no compatibility switch). Implemented with lex_isident5 in lj_lex.c; new
tests/d54/lex_02_identifiers.lua asserts the same normalized syntax error as
PUC for UTF-8/byte>=128 identifiers and that ASCII names still load.

## Session 30 (branch i64-ffuncs) — standard library with int64, GC drive, GC stress harness

Interpreter: lj_lib_checknum/checknumber/checkint take boxed/widened
integers (checknum read a widened value's low word); math.min/max exact in
C; floor/ceil keep integers; fmod(x,-1)=0 and "zero" wording; random
returns int64; `..`/table.concat/%q format boxes; string->number keeps
integer syntax as integers of any size (hex wraps), tonumber with base
wraps; 5.4 wording for string.rep/char and table.insert bounds. GC: a boxed
arithmetic result now drives the collector (300k xorshift steps under -joff
went 1 MB -> 131 MB before); arm64 VM reloads BASE after lj_meta_arith/
bitop. Recorder: tostring/tonumber/string.format/math.abs/min/max/FP math
and `..` take int64 arguments (lj_strfmt_i64, lj_i64_abs/min/max IR calls;
lj_ir_tonum/tostr understand IRT_I64). Harness: --gc-stress (setpause 0 in
every arm), wired into ci-box.sh for the i64/close/coro/gc/bits tests.
Details: docs/adr-001b-boxed-i64.md "Step 4".
Gates at 6bd96596, both arches identical: A+B 83 PASS / 0 FAIL / 12 XFAIL
/ 1 XPASS (math_02_random A, now removed from known-bad), opt 0-3 188
PASS (+4 XFAIL math_os_01 B), R 48, GC stress 57/0/3, C API + i64 14/14,
fuzz 160/160. Bench JIT arms unchanged (arm64 B1 16.6, B2 1496.6, B2b
148.9, B3 23.0 / 215.2 ms; x64 B1 30.5, B2 3211.6, B2b 677.8, B3 47.7 /
955.5 ms); -joff arms faster/leaner from the GC drive (arm64 B1 12036 ->
3996 ms, B2 522 -> 190 MB).

## Session 31 (branch bits-mm) — 5.4 bitwise metamethods

__band/__bor/__bxor/__shl/__shr/__bnot: MMDEF gains the six ids (appended
after close, arith ids stay). lj_meta_bitop returns a metamethod call base
like lj_meta_arith: two numbers take the integer path (which raises
"number has no integer representation" itself), otherwise the metamethod
of the first, then the second operand is called (__bnot with the operand
twice), else the 5.4 "attempt to perform bitwise operation on a <type>
value" error; both VMs branch to vmeta_binop on a non-NULL result. The
recorder dispatches BC_BNOT/BAND/BOR/BXOR/BSHL/BSHR with a non-number
operand through rec_mm_arith (BSAR is LuaJIT-only). bits_02_metamethods
passes in A and B (removed from known-bad); a hot loop over metamethod bit
operators compiles.
Gated together with session 32 (rand-rec contains bits-mm): see below.

## Session 32 (branch rand-rec, on bits-mm) — math.random in the JIT, widened-int C API fixes

recff_math_random now calls lj_math_random_f/_0/_i, which step the
xoshiro256** RandState exactly as the interpreter does (integer bounds only,
interval guarded, results narrowed to int32 when both bounds fit): the B
half of math_os_01 passes and a hot loop over math.random compiles.
Found on the way: numberVnum() and lua_tointeger/lua_tointegerx read the
low word of a widened 47-bit integer (tvisint is true for both forms), so
math.random(1<<40, ...) in the interpreter returned values without the
lower bound -- fixed at the root (numberVnum feeds many library paths).
math.modf pushes the integral part as an integer when it fits (lmathlib
pushnumint), which was the last A difference of math_os_01. The C API
box test anchored nothing and passed by allocator address reuse; it now
keeps the value on the stack across the collection.
Also: a NaN prints with its sign like printf (math.sqrt(-1) is -nan on x86,
nan on arm64; math_os_01 A differed on x64 only). Gates at 5d32b00c
(rand-rec = bits-mm + this), both arches: A+B 89 PASS / 0 FAIL / 10 XFAIL
/ 1 XPASS, opt 0-3 196 PASS / 0 FAIL / 0 XFAIL / 4 XPASS (the XPASSes are
DeepSeek's dump_03_version B entry, which passes), R 50, GC stress 58/0/2,
C API 81 + i64 14/14, fuzz 160/160. bits_02_metamethods and math_os_01 left
known-bad. Bench JIT arms unchanged: arm64 B1 16.5, B2 941.9, B2b 127.3,
B3 23.6 / 209.5 ms; x64 B1 30.3, B2 3208.1, B2b 658.8, B3 47.8 / 940.1 ms. Deferred: err_02_tailname (PUC keeps
the Lua caller's frame alive when a C function is tail-called, so
lua_getinfo finds 'rep' from the TAILCALL; LuaJIT's CALLT replaces the
frame -- matching it means non-tail calls to C functions in the VM, not a
cheap change).

## Session 33 (branches jitutil-i64, corpus-ext) — JIT tooling smoke, real-program corpus

jitutil-i64: the step-3-era -jv/-jdump segfault on boxed literals no longer
reproduces on either arch (canonical literal folding + BCDUMP_KTAB_I64 fixed
it on the way); tests/jitutil-smoke.sh (-jbc/-jv/-jdump=bimT/-jdump=+rs/-jp
over six int64-heavy tests, 30 runs) is a ci-box stage.

corpus-ext: tests/corpus-ext/run.sh runs the test suites of Penlight 1.14.0
(37 scripts), serpent 0.30, luaunit 3.4, rxi json.lua 0.1.2 and dkjson 2.8
under PUC 5.4.7, -joff, -jon and -jon with the GC on every allocation;
archives pinned by sha256 in manifest.tsv, kept in .dlcache/ (no network on
the boxes). Normalized away: addresses, timings, interpreter name, "[C]: in
?" vs "[C]: at 0x...", the "no file ''" line. Results (both arches equal):
Penlight and rxi json SAME in all arms; serpent and dkjson differ only by
pairs() order / string.dump bytes (known-diff, IMPL-DEFINED); luaunit under
jit.version=_VERSION differs only because _VERSION is "Lua 5.1" (lua.h
LUA_VERSION) -- it then runs its 5.1-only tests (math.fmod(1, 0) is NaN in
5.1, the 'zero' error in 5.4) and the 5.1 prettystr branch. VM finding for
the C API owner: LUA_VERSION must be "Lua 5.4". Library-level findings
(DeepSeek): tracebacks print "[C]: at 0x..." where PUC prints "[C]: in ?";
module-not-found messages list "no file ''" for the ";;" default path
expansion. lua-MessagePack needs lua-TestAssertion (not fetchable pinned
today), inspect.lua needs busted: pinned, not run. The GC-stress arm never
differed from -jon. -0.0 / 1/-0 / 1/(-0.0) match PUC exactly.
Gates at 2c97250b (corpus-ext, contains jitutil-i64), both arches identical:
A+B 89 PASS / 0 FAIL / 10 XFAIL / 1 XPASS (dump_03_version B, DeepSeek's
entry), opt 0-3 196/0/0/4, R 50, GC stress 58/0/2, JIT tooling smoke 30/30,
corpus "arms same 6, unexpected diffs 0", C API 81 + i64 14/14, fuzz
160/160. Test/tooling-only branches: no bench run.

## Session 34 (branch b2-sort) — B2 gap: inline int64 compares, exact lua_lessthan

ISLT/ISGE/ISLE/ISGT compare two 5.4 integers of any encoding (int32,
widened, box) inline in both VMs; lua_lessthan (table.sort default) is
exact (it compared widened values by their low word); interning reuses the
lookup probe for the insert. B2 split arm64 ms (PUC / before / after): fill
24 / 137 / 122, sort with comparator 526 / 790 / 708, default sort 151 /
564 / 402; the rest is the boxing itself (two scattered dereferences per
comparison) -- see the ADR note. Also: exact float->int64 conversion with
a range check (2^63 passed as an integer on arm64 in bitops, floor/ceil,
constant folding, io); boxes are "number" in compare error messages.
Test: sort_02_int64.
Gates at 4fe1f9c5 (main 4a6fbbd7 merged), both arches identical: A+B 93
PASS / 0 FAIL / 8 XFAIL / 1 XPASS (dump_03_version B), opt 0-3 200/0/0/4,
R 51, GC stress 58/0/2, JIT tooling smoke 30/30, corpus 6/0, C API 81 + i64
14/14, fuzz 160/160. Bench arm64 (JIT): B1 16.7, B2 929.6 (822-942 across
runs on the shared escher; was 1496.6; FFI 618, PUC 544), B2b 163.2, B3 21.1
/ 219.2 ms. x64 (JIT, main 4a6fbbd7 measured back to back as reference):
B1 30.3 (main 30.3), B2 3179.1 (main 3242.9), B2b 793.2 (main 654.5), B3
47.7 / 1013.3 (main 47.7 / 934.1) ms. B2b: main sorted the widened values
by their low word (lua_lessthan bug) -- the exact 64-bit comparison is the
+21 %; B3-table +8 % on int32 only, within one run each, left as measured
(the int32 path is the same single compare plus one or/test on the tag
words). Earlier version 62541a67 (lj_i64_getint call per operand) cost
15-40 % on both and was replaced.

## Session 35 (branch dbg-hooks) — 5.4 debug hooks under the JIT

Debuggers and profilers set hooks with debug.sethook; LuaJIT 2.1 kept most
of the 5.1 behaviour (line events on every instruction with a new line,
hooks ignored inside compiled loops, no return events for C functions, no
tail-call events, one global hook). PUC-Lua 5.4.7 testes/db.lua was the
characterization: its 266 line-event cases (if/then, loops, large gaps
between lines, returns into the caller) all failed before, 0 after; the
whole file now runs to the two places that need no-hook tail-call
tracking (below) and the `nups` count for `_ENV`.

What changed (interpreter, both VMs, debug library):

* Line events follow PUC 5.4 luaG_traceexec: an event when the line
  changes or the pc goes backwards (loops), none for LuaJIT's LOOP/ILOOP
  counting op, entering a function fires for its first instruction,
  returning into the caller continues the call's line (PUC's rethook sets
  oldpc to the call), the line that calls debug.sethook gets no event of
  its own (the saved pc is set to the calling instruction), stripped
  chunks fire the first instruction with line nil. The parser attaches
  the operator's line to arithmetic/concat/compare instructions
  (luaK_fixline) and emits the `if`/`elseif` branch after `then`, so
  multi-line conditions report the line PUC reports. The "previous pc
  belongs to another function" test compares addresses with the proto's
  bytecode range instead of a truncated index.
* Hooks disable the JIT: while any hook event is set the dispatch table
  neither counts nor enters traces (`lj_dispatch_update`), and
  debug.sethook flushes all traces so a hook set inside a hot loop fires
  for the rest of the loop (the patched loop bytecodes fall back to the
  interpreter). A hook set by a function called from a running trace takes
  effect at the next interpreter instruction after the trace exit.
* "tail call" events (LUA_HOOKTAILCALL = 4, 5.4's name for the slot of
  LuaJIT's unused tail-return event): with a call hook set, CALLT/CALLMT
  dispatch through the ins hook (`lj_vm_rethook` as the stub), which notes
  the frame base in `g->tailofs`; `lj_dispatch_call` consumes it (cleared
  by errors and by lua_sethook). Tail calls to C functions are plain
  "call" events, as in PUC. `debug.getinfo(level, "t").istailcall` comes
  from a per-thread bitmap of frame bases marked by the tail-call event
  and cleared by any later plain call at or below that base; the bitmap is
  valid for the current hook epoch only (`g->hookepoch`, bumped by
  lua_sethook), so it is exact under a debugger and false otherwise.
* Return events for every kind of function: Lua (as before), C functions
  (`lj_dispatch_cret`, called from FUNCC/FUNCCW after the function
  returned -- so debug.sethook's own return is the first event, as in
  PUC), ASM fast functions (`lj_dispatch_ffret` from `fff_res`: the
  function object is remembered by the call event in `L->hookff`, the frame
  is reconstituted for the hook by moving the results up two slots and
  back), pcall/xpcall (`lj_dispatch_pret` from vm_returnp and from the
  error unwind, before the status boolean overwrites the frame link; the
  hook sees the boolean through a temporary copy of the results) and
  coroutine.resume/wrap (same helper, normal and error paths). A fast
  function whose fallback handler returns FFH_RETRY is re-dispatched
  through its header; `g->ffretry` (set by the VM on that path) suppresses
  the second call event.
* `debug.getinfo` options `t` (istailcall) and `r` (ftransfer/ntransfer;
  the values are the call arguments resp. the results, indexed the way
  debug.getlocal(2, i) in the hook sees them -- the index itself differs
  from PUC for C functions that return in place), getlocal names
  "(temporary)" / "(C temporary)" / "(vararg)".
* Functions called by the hook machinery are "hook '?'" frames
  (`namewhat == "hook"`, `g->hookbase`), and debug.traceback uses PUC's
  pushfuncname wording throughout ("in function 'string.rep'" for
  functions found in package.loaded, "in local 'f'", "in upvalue 'g'",
  "in field 'x'", "in method 'm'", "in metamethod 'close'", "in hook '?'",
  "in function <file:line>", "in ?" for C functions without a name).
* Per-coroutine hooks: `debug.sethook(co, f, mask)` and `debug.gethook(co)`
  keep the hook function per thread in the registry's `_HOOKKEY` table
  (weak keys, as PUC) and the mask/count per thread in a second weak
  table; the global hook mask is the union over all threads, the hook
  function filters by the running thread's own mask. C-API hooks
  (lua_sethook with another function) still show as "external hook".

Three deliberate differences from PUC, all documented in the test header:
istailcall is false when no call hook was set at the time of the call (a
frame-link bit would cost a masked load on every return path in both VMs
and in the JIT's RETF guard); PUC's count hook clobbers its oldpc with the
hook function's pcs and then fires an extra line event -- not replicated,
so count hooks and line hooks are not combined in the test; and `nups`
does not count an `_ENV` upvalue for functions that only use globals
(LuaJIT's GGET model; db.lua expects 2 for such a function). Library note
for the C API owner: `debug.getinfo(print, "u").nups` is 1 here (db.lua
711 expects 0).

Test: debug_02_hooks (12 sections, A vs PUC and B JIT vs interpreter,
including a hook set inside a compiled loop, a count hook armed mid-loop
and a call hook set by a function called from a running trace).
Files: lj_dispatch.c/.h, lj_debug.c/.h, lib_debug.c, lj_parse.c, lj_obj.h
(lua_State: tailbits/tailhi/tailepoch/hookff; global_State: hookbase,
hookepoch, hookftransfer/ntransfer, tailofs, ffretry), lj_state.c,
lj_err.c/.h (lj_err_funcname_loaded exported), lua.h (LUA_HOOKTAILCALL,
lua_Debug istailcall/ftransfer/ntransfer), vm_arm64.dasc, vm_x64.dasc.
Gates at 5eaff309 (main 5316a836 is its ancestor, no merge needed), both
arches identical: A+B 95 PASS / 0 FAIL / 8 XFAIL / 1 XPASS (dump_03_version
B), opt 0-3 204/0/0/4, R 52, GC stress 58/0/2, JIT tooling smoke 30/30,
corpus 6/0, C API 81 + i64 14/14, fuzz 160/160. No bench (hooks cost
nothing while no hook is set: the only new instructions on hot paths are a
hookmask load+branch after a C-function return and at fast-function
return, both behind the existing hookmask byte).
First run of an assert build (-DLUA_USE_ASSERT -DLUA_USE_APICHECK) over
the whole suite, arm64: three findings fixed on this branch -- the main
thread's tail bitmap leaked at close (32 bytes), the int64 key conversion
in rec_idx_key carried check mode 0 (the narrowing fold's assert), and
select(i, ...) typed a boxed int64 vararg as UDATA (rec_check_slots); the
assert suite is green afterwards (A+B 95/0, opt 204/0, GC stress all d54
198/0, fuzz 240/0, smoke 30/30). The x64 assert build segfaults at start-up
on main as well (5316a836, `-DLUA_USE_ASSERT` alone, `luajit -e
'print(1)'`): pre-existing, not investigated here; a Debian 13 gcc on pve2.
tests/soak/gc-soak.sh is the overnight GC soak (item 4): GC-stress harness
over all of d54 (A, B@0, B@3, R), the fuzzer with a fresh seed per round
and the real-program corpus, in a loop; one summary line per round,
failure details only; a round takes ~5 s on the arm box (the suites are
small), so 8 h is several thousand rounds with thousands of fuzz seeds.

Known issue (filed 2026-11-16, owner: VM, after udata-uv): the x64 assert
build segfaults at start-up on main. `make CCDEBUG=-g
XCFLAGS=-DLUA_USE_ASSERT` at 5316a836 on the x64 box (Debian 13 gcc), then
`src/luajit -e 'print(1)'` -> SIGSEGV; the plain `-g` build runs, the arm64
assert build runs the whole suite. An ASan+assert build crashes in
lj_alloc (tmalloc_small via lj_tab_resize during parsing) with a bogus
frame pointer, i.e. memory corruption before the first chunk runs, not an
assertion. First suspects: an assert-only code path in the x64 VM/C glue
(LJ_GC64 + LUAJIT_NUMMODE=2) or a struct whose size changes with
LUA_USE_ASSERT between buildvm and the C side.


## Session 36 — corpus 5.4: pack/io/int64 keys, loader and interpreter surface

Pushed 08325f52..96227610 (rebased on 40f616db). Both boxes: d54 A+B 101 PASS
/ 5 XFAIL, opt 212, R 53, GC-stress 59+1X, capi 84, i64 14, fuzz 160, corpus-ext
9 SAME / 0 unexpected.

Fixed: string.pack/unpack/packsize (already present, corrected for int64 and
PUC checks); hex integer literals wrap modulo 2^64 with any digit count;
lua_geti/lua_seti exact boxed int64 keys and the C API box branches in
lua_tointeger/lua_tonumber; table.unpack/move int64 indices, table.insert/sort
through luaL_len; io.close/file-method split, io.lines EOF close + the 5.4
4-value to-be-closed shape + MAXARGLINE 250, io read 'n' exact int64; dofile as
a Lua wrapper (yields); loadfile BOM/shebang including line numbers; luajit -l
PUC global names ('=' and '-suffix'); print line flush; coroutine.yield wording
without location; traceback metamethod names and C-frame "in ?" (Fable's
pushfuncname rewrite, kept our __ strip); LJ_MAX_UPVAL 255; duplicate labels
are rejected function-wide like PUC (corpus goto.lua passes); non-ASCII lexer
tokens print '<\239>'.

Cleared known-bad: tpack, big, utf8, bitwise, constructs, goto, d54 env_01,
dump_str_01, attrib_01. Remaining corpus rows: db/files (debug 5.4, Fable
lib_debug), math (string arithmetic coercion in the VM), pm/literals (long
string interning / %p identity), main (corpus lacks libs fixtures; progname
and argv), sort (IMPL-DEFINED counters/timings), PERF rows. Remaining d54 rows:
dump_02_border, tbl_03_border_divergence, dump_03_version (fork), err_02_tailname,
gc_01_tbc_gc.

process: the mandated agent reviewer blocked lua_seti's missing boxed-key pop
and io double-close before the push; both fixed. Both delegated coder branches
(utf8, goto) contained no usable code and were discarded.
## Session 36 (branch udata-uv) — userdata user values (lua_newuserdatauv n > 1)

5.4 user values are now a TValue array behind the 8-byte aligned payload:
GCudata.nuvalue (the former alignment pad) holds the count (0..65534, PUC's
api_check range, an error here), lj_udata_newuv allocates and nils them,
gc_mark marks them with the userdata (userdata are black at once, so
lua_setiuservalue uses the forward barrier), sizeudata covers them for
free and accounting. Internal userdata (io handles, int64 boxes, buffers,
clib) have none; the earlier single value lived in ud->env and could hold
GC objects only, env is the 5.1 fenv view again. lua_getiuservalue /
lua_setiuservalue copy any value; debug.getuservalue(u, n) returns value,
true or fail, debug.setuservalue(u, v, n) returns u or fail (ldblib 5.4).
io file handles are created with zero user values like PUC's newprefile.
Tests: capi (4 values of mixed types on a 3-byte payload, GC survival,
objlen), d54 debug_03_uservalue (the Lua-visible surface). Library note:
lua.h has no lua_rawlen (5.2+ name of lua_objlen) -- C modules built
against our headers that use it will not link; for the C API owner.

## Session 37 (branch corpus-cmod) — real-program corpus with C modules

LPeg 1.1.0, lua-cjson 2.1.0.14 and LuaFileSystem 1.8.0 (pinned tarballs in
.dlcache, sha256 in tests/corpus-ext/manifest.tsv) are built on the boxes
twice: against PUC's headers (tests/ref/src/lua-5.4.7/src, left behind by
fetch-ref.sh) for the PUC arm and against ours for -joff/-jon/-jon+GC
stress; LUA_CPATH per arm. LFS also unlocks Penlight's five LFS-dependent
scripts (they used to fail under PUC too). Results and findings:

* LPeg: all arms SAME (1667-line suite incl. re.lua).
* lua-cjson: SAME apart from pairs() order of object keys (impl-defined,
  known-diff). Real finding fixed here: lua_pushnumber canonicalised every
  injected NaN to the negative quiet NaN, so cjson's decoded "NaN" printed
  "-nan" where PUC prints "nan"; the sign is kept now (a positive quiet NaN
  never aliases a tagged value).
* LuaFileSystem: lfs.setmode/lock read the FILE* userdata as 5.4's
  luaL_Stream {FILE *f; lua_CFunction closef}; ours is {FILE *fp; uint32_t
  type}, so closef reads the type word (plus padding -- one arm passes by
  luck). Library finding (lib_io), known-diff with the reason.
* Penlight (42 scripts now): test-pretty failed because _G held an "_ENV"
  entry (luaopen_base and load(..., env) materialised it; PUC's _ENV is an
  upvalue, _G._ENV is nil) -- removed, the VM/recorder special case on the
  interned key serves reads and writes. test-tablex failed because ipairs
  ignored __index (5.3+ semantics; tablex.readonly is a proxy): tables
  with a metatable now take the C path of ipairs_aux (lua_gettable), the
  recorder leaves them to the interpreter; d54 meta_04_ipairs. Remaining
  (known-diff, queued as the next VM item "env-uv"): test-class,
  test-class2, test-__vector and test-utils3 need `_ENV` to be visible as
  an upvalue (debug.getupvalue(f, n) == "_ENV", setupvalue/upvaluejoin on
  it) -- Penlight's compat.getfenv/setfenv, like PUC's db.lua:722 and its
  nups count. Plan: a parser flag (PROTO bit 0x40 is free in pt->flags
  after fs_finish) marking functions that touch globals or contain one
  that does (main chunks always), and the debug API (lj_debug uvname,
  lua_get/setupvalue, debug.upvalueid/upvaluejoin, getinfo nups)
  synthesising "_ENV" as upvalue 1 backed by fn->env, real upvalues shifted
  by one. No bytecode or VM change.
* C API headers (DeepSeek): all three modules compile against our headers
  only with tests/corpus-ext/shim-ours.h -- lua.h/luaconf.h/lauxlib.h lack
  lua_rawlen, lua_getuservalue/lua_setuservalue, lua_Unsigned/LUA_UNSIGNED,
  LUA_INTEGER_FMT/LUA_INTEGER_FRMLEN, luaL_Stream/LUA_FILEHANDLE (also
  luaL_checkversion, lua_pushglobaltable, not hit yet). The runner prints
  "shimmed" for every build so the gap stays visible; the shim shrinks as
  the headers grow.

## Session 38 (branch env-uv) — `_ENV` as a visible upvalue

PUC's `_ENV` is upvalue 1 of every main chunk and an upvalue of every
function that (itself or through a nested function) touches a global, at
the position of its first use in upvalue-creation order. Debuggers,
sandboxes and Penlight's compat.getfenv/setfenv find and replace it with
debug.getupvalue/setupvalue/upvaluejoin; PUC's db.lua checks the name,
the position and nups. The bytecode here keeps LuaJIT's GGET model (no
such upvalue, globals go through fn->l.env), so the debug API synthesizes
it: the parser records the position (pt->envuv = position + 1; fs_markenv
at every GGET/GSET emission walks the enclosing functions like PUC's
upvalue resolution; main chunks always 1), lj_debug_uvnamev/lua_getupvalue
present "_ENV" there with the env table as its value and shift the real
upvalues by one, lua_setupvalue sets the closure's env (tables only, else
no such upvalue), lua_upvalueid gives the env table's address,
lua_upvaluejoin copies the table (into the env, or into a real upvalue),
getinfo nups counts it. The dump carries envuv behind a dump-only flag bit
(PROTO_DUMP_ENVUV in the flags byte, 0x08 is unused there), so older
dumps still load. No VM or recorder change; UGET indices in bytecode are
untouched (error messages name upvalues by bytecode index as before).
Deliberate difference: PUC's closures of one chunk share one _ENV cell, so
setupvalue on one changes all of them; here the env is per closure. The
"unique upvalue" setfenv idiom (upvaluejoin to a fresh closure, then
setupvalue) behaves the same in both, which is what Penlight and the
lua-l recipe rely on. Test: env_04_upvalue (names/positions for main
chunk, first-use order, nested-only use, none; values; setupvalue; the
setfenv/getfenv idiom; upvalueid identity; dump round trip; hot loop with
a swapped env). PUC db.lua now runs to its first no-hook istailcall check
(line 633) -- the nups and getupvalue sections pass. Corpus: Penlight's
test-class, test-class2, test-__vector and test-utils3 pass; the runner
wraps each arm's flags in a script so arg[-1] is an interpreter path
(test-utils re-executes it) and normalises the interpreter banner.
Once seen, not reproduced in 10 further runs: test-utils.lua:40
(executeex of `quit` expected exit code 255) failed under all three arms
of ours in one full corpus run; the probe shows identical popen/os.execute
status reporting; kept in mind if it shows up in the soak.

Resolved (session 38): the "x64 assert build segfaults at start-up on
main" known issue was a build-recipe artifact, not a VM bug. `make
XCFLAGS=-DLUA_USE_ASSERT` replaces the Makefile's `XCFLAGS+=
-DLUAJIT_NUMMODE=2` (GNU make command-line variables override assignments),
so x64 built in single-number mode: the lexer scanned integer literals
with STRSCAN_OPT_TONUM, lex_number then boxed every integer literal, the
parser registered the box as a GC constant while fs_fixup_k saw a numeric
key and wrote it as a number constant past the prototype (ASan:
heap-buffer-overflow in fs_fixup_k, 16 bytes past a 149-byte proto for
`print(1)`), which lj_alloc's slack usually hid. arm64 is dual-number by
architecture and never saw it. lj_arch.h now refuses non-dual builds with
an #error; extra defines go in CFLAGS (`make CFLAGS="-DLUA_USE_ASSERT
-DLUA_USE_APICHECK"`), which the Makefile appends. The arm64 assert-build
runs in sessions 35-38 were valid (dual by default).


## Session 39 — math 5.4, C-API surface, luaL_Stream, C-module corpus

Math functional corpus now passes in mode A: string->number coercion in
arithmetic (float and integer forms), unary minus, explicit-base tonumber rules
(no 0x prefix; embedded NULs; inf/nan rejected; no-base keeps exact int64),
lua_tointeger(x) exact numeric strings, math.atan(y,x)=atan2, math.max/min()
"value expected", bitwise NUMNOINT variable context, and float modulo as 5.4
luaV_modf (C fmod then divisor-sign adjust; BC_MOD* routes through
lj_meta_arith so the exact path also covers |x/y| > 2^52). Only printed random
statistics differ (IMPL-DEFINED, A) and JIT integer floor division with a
negative divisor still yields nil under -jon (B, Fable recorder area).

C API 5.4 surface filled: lua_rawlen/lua_Unsigned, lua_get/setuservalue,
lua_tounsignedx, lua_pushglobaltable, luaL_checkversion,
LUA_INTEGER_FMT/LUA_INTEGER_FRMLEN/LUAI_UACINT/LUA_MAX*INTEGER, LUA_FILEHANDLE,
luaL_Stream, luaL_checkunsigned/optunsigned. IOFileUD starts with the PUC
luaL_Stream prefix {FILE *fp; lua_CFunction closef} (type moved to offset16);
opened files carry closef, std/popen handles NULL. debug.getinfo on library C
functions reports nups 0 while Lua functions keep Fable's _ENV-inclusive count.

tests/corpus-ext/shim-ours.h is deleted. luafilesystem, lpeg and lua-cjson build
against our headers only and run on x64 and arm64; full corpus-ext x64: 15 arms
SAME, 0 unexpected (cjson pair order known IMPL-DEFINED). collectgarbage now
returns the previous GC mode string for "generational"/"incremental"
(GCState.gcmode), matching PUC's observable API. gc_01's remaining divergence
is table __gc finalizers (LuaJIT finalizes userdata only).
## Session 39 (branch x64-redzone) — first x64 assert-build run

With the build recipe fixed (`make CFLAGS="-DLUA_USE_ASSERT
-DLUA_USE_APICHECK"`), the x64 assert suite ran for the first time. One
finding: `lj_asm.c checkmclim: red zone overflow` on i64_01_box and
i64_04_keys in mode B -- the x86/x64 int64 sequences for EQ (op 8) and
HLOAD (op 67) with a boxed/widened operand (load the udata pointer, check
the type, load the payload, widened fallback) emit more than the 64-byte
machine-code red zone for a single IR. The red zone only guards the
distance to the mcode limit check; the sequences themselves are correct.
MCLIM_REDZONE is 128 on x86/x64 now (arm64's fixed-width sequences stay
below 64). The rest of the x64 assert suite was already green (fuzz 240/0,
GC stress all d54 212/3 with only this assert).




## Session 40 — files.lua byte-identical to PUC; debug for-state view

tests/corpus/puc54/files.lua now passes in mode A on x64 and arm64 (known-bad
row removed). Fixes: debug.getlocal presents numeric/generic-for hidden locals
as four "(for state)" entries in PUC's gen/state/control/toclose order (LuaJIT
physically stores toclose first for ITERC, so the debug view remaps slots);
loadfile sees a binary chunk after a '#' comment line (no synthetic newline
before ESC); explicit nil env sets _ENV nil (arm64 GGET NULL-env pushes nil);
PUC load-mode error wording; io.popen POSIX mode validation; os.date formats
literal bytes piecewise so NULs survive (only specifiers through strftime);
lua_tointeger(x) requires exact integral floats. db.lua remains known-bad at
line 619: istailcall is true in PUC without a hook, while Fable's tail marks
exist only while a call hook is installed.

Deliberate divergence (Markus decision, 2026-11-16): LuaJIT interns every
string by design (interning/hash/equality, table string keys, JIT constant
folding all rely on pointer equality). PUC 5.4 does not intern long strings
(> LUAI_MAXSHORTLEN), so `%p`/lua_topointer identity after concat/gsub differs.
The observable is only debug identity; un-interning long strings would be a
large VM change. The corpus copies of literals.lua:231 and pm.lua:436 therefore
assert the values but not `%p` identity, with the reason inline; both known-bad
rows are removed.

Session 41 (same day): lex_number now follows PUC read_numeral (digits/xdigits/
dot, one exponent with optional sign, exactly one trailing letter/underscore;
the 0x 'x' is saved explicitly), and an <eof> near-token is unquoted. This made
corpus literals.lua byte-identical. Corpus A now passes for files, literals, pm,
constructs, goto, big, tpack, utf8, bitwise, verybig and all d54 tests except
the documented rows. Remaining corpus: db (istailcall without a hook), sort
(IMPL-DEFINED counters/timings), main (missing libs fixtures; PUC stops there),
and PERF rows.

## Session 42 — reference switched to PUC-Lua 5.4.9 (final 5.4 release)

Lua 5.4.9 (25 Aug 2026) is the last 5.4 release. The vendored reference is now
tests/ref/dist/lua-5.4.9.tar.gz (lua.org sha256
2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6) and the
test suite comes from lua/lua GitHub tag v5.4.9 (commit
312b9efaa1061c2c4cad08554dbc1351c3270eef). fetch-ref.sh, ci-box and the corpus
helper paths use 5.4.9; `fetch-ref.sh --corpus` reapplies the three local
adaptations via tests/ref/corpus-adapt.py.

Manual diff 5.4.7->5.4.9 (doc/manual.html): no semantic changes — copyright
year, two-complement -> two's complement, spacing in `{10,20,...}` examples,
"and it excludes also" -> "and it excludes also", "mutlres" typo fixed,
timestamp. lua.org/bugs.html: 5.4.9 lists no own bugs (last release note);
5.4.8 fixed four (all-weak table metatable revisited; `lua --` without script;
constructor item counter overflow; finalizer stack-leak); 5.4.7 fixed eight
(REPL multiline EOF message, VJMP index codegen, 16-bit local limit, panic
lua_status, emergency GC weak __newindex, luaD_seterrorobj unprotected, closing
message handler, plus entries listed on the page).

5.4.9 teste/ additions versus the previous corpus: api panic threadstatus,
closure `_ENV[1 < 2]` 5.4.7 codegen fix, coroutine message-handler overwrite on
close, errors `('_ENV').x + 1` wording, events weak-__newindex emergency GC,
gc all-weak table (T hook), main `--`/REPL cases. The new non-T-hook tests
(closure, coroutine) pass mode A on x64 and arm64; tests needing PUC's internal
T hooks (api/errors/events/gc) remain auto-skipped by the harness. No output
changes were needed.
Both boxes: ci-box A+B 107 PASS/5 XFAIL, opt 224, R 56, GC 59+1X, capi 101,
i64 14, fuzz 160/0; corpus-ext 15 arms SAME / 0 unexpected. Reference banner is
now `Lua 5.4.9 Copyright (C) 1994-2026 Lua.org, PUC-Rio`.


## Session 43 — math and sort corpus pass; adaptation policy

math.lua and sort.lua now pass modes A and B on x64 and arm64; their known-bad
rows are removed. Both only printed process-/implementation-defined values that
no differential harness can compare: math printed the OS-drawn random seed and
PRNG statistics (all its distribution assertions pass), sort printed os.clock
timings and the comparator call count (all order assertions pass). The corpus
adaptations now omit those prints while keeping every assertion; they are
reapplied by tests/ref/corpus-adapt.py after fetch-ref --corpus, alongside the
constructs/literals/pm adaptations.

Remaining known-bad after this: corpus calls (hang at xpcall(loop,loop)
C-stack-overflow handling, >600s; VM owner), closure (JIT-on slowdown), db
(istailcall without a hook), main (missing libs fixtures + interactive prompt
environment), heavy (PUC reference timeout); d54 only the documented border/
fork/tailname/table-__gc rows.

## Session 44 — C API 5.4 getter/raw signatures and tests

lua_gettable/getfield/rawget/rawgeti/geti return lua_type like PUC 5.4 (void in
LuaJIT 2.1); lua_rawgeti/rawseti take lua_Integer and handle exact int64 keys
(rawseti roots a boxed key during the allocating raw set); lua_rawgetp and
lua_rawsetp are added. tests/capi covers luaL_checkversion,
lua_pushglobaltable, lua_rawlen (string and table without __len),
LUA_INTEGER_FMT, maxinteger rawgeti/rawseti, and lightuserdata rawgetp/setp:
108 checks, 0 failures. corpus-ext C modules (lfs, lpeg, cjson) still build
against our headers and pass on x64 (3 SAME arms for lfs/lpeg; cjson known
pair-order diffs). Both boxes ci-box green (109/0/5, opt228, R57, GC59+1X,
capi 112, i64 14, fuzz 160/0). Further 5.4 surface in the same session:
lua_getglobal/setglobal are real functions (getglobal returns the type),
lua_version returns lua_Number 504 (5.4 signature, not LuaJIT's pointer form),
luaL_tolstring, luaL_requiref and luaL_typeerror are implemented, with
LUA_LOADED_TABLE defined; capi tests cover version/tolstring/requiref.

## Session 45 — message-handler re-entry bound (small commit)

`lua_State` gains depth-relative `errnest`/`errnestofs`; `lj_err_run` bounds
message-handler re-entry at `LJ_MAX_XLEVEL` (200) and raises PUC's exact
"error in error handling" object. The count is reset on ERRERR exit (including
handler-failure unwinds) so healthy handlers are unaffected. New d54 test
`err_03_handler_reentry.lua` drives a handler that resets status with pcall and
then errors; it passes A/B/R on both boxes in well under a second. Calls.lua
stays known-bad in mode A with the remaining VM work (pcall nesting bound and
`__call` chain argument prepending) parked on branch `wip-calls-vm`, plus the
arbitrary-`_ENV` blocker at line 359.

## Session 46 — main.lua interpreter parity; C corpus fixtures built per box

`tests/corpus/puc54/main.lua` passes modes A and B on arm-box and x64-box.
`tests/ref/build-puc54-libs.sh` (called by fetch-ref.sh) builds lib1, lib11,
lib2, lib21 and lib2-v2 from the vendored PUC 5.4.9 headers into the corpus
libs directory on each box, so package.loadlib/-l sub-tests have their
fixtures. `src/luajit.c` gains the PUC `-W` option (enables warnings through
lua_warning("@on")) and collects the flag. Corpus adaptations omit three
process-defined outputs: the interpreter pathname, the os.tmpname filename and
the exact `-v` banner; the remaining assertions still run. The interactive
prompt sub-tests are fully scriptable over piped stdin (custom _PROMPT/
_PROMPT2), and the Ctrl-C checks use shell `kill`; no TTY is required. Mode R now passes too: the dump/reload wrapper mirrors the interpreter's
negative arg entries (arg[-1] option, arg[-2] progname), so files.lua and
main.lua can spawn the interpreter in the reload arm.

## Session 47 — heavy.lua OOM quarantined from the default corpus

A full mode-A corpus run including tests/corpus/puc54/heavy.lua peaks at the
8 GiB x64-box/arm-box scope limit and the kernel OOM-kills the whole job; the
test killed at that moment appears as an unrelated random FAIL (attrib, files,
math). Runner discovery now excludes puc54/heavy.lua by default. It remains
known-bad (PERF/memory) and can only be run as an explicit `--include-heavy`
stage alone on a box with more than 8 GiB. The other corpus files measure at
96 MiB peak or less serially (errors.lua 96 MiB, constructs 89 MiB), so serial
runs below the cap no longer have a memory hog.

## Session 48 — corpus memory/OOM triage, lib2-v2 loader, dump-reload args

`tests/corpus/puc54/heavy.lua` is the real memory hog: the PUC reference peaks
at the 8 GiB box cap and the kernel OOM-kills the whole scope, making whichever
test is running look like a random FAIL. Runner discovery now excludes it by
default; `--include-heavy` is an explicit stage for a box above 8 GiB, and the
known-bad row records PERF/memory. With heavy excluded, a serial PUC mode-A
scan of every corpus file peaks at 96 MiB (errors.lua), so the other files are
not memory sources.

Two non-memory failures had root causes and are fixed:
- attrib A: LuaJIT's `ll_loadfunc` only built `luaopen_Y` for `X-Y` module
  names; PUC first tries `luaopen_X` and then the old-style `luaopen_Y`.
  lib_package now does the same, so `lib2-v2.so` (symbol `luaopen_lib2`)
  loads. -l semantics stay PUC's: require gets the full name, the global is
  cut at the version mark.
- files B: the corpus printed the wall-clock date/time; two arms can straddle a
  second boundary. The date/time print is now a stable "test done" line.
- files R/main R: dump_reload.lua set only arg[0], so scripts that derive
  progname by walking negative arg indices spawned `files.lua` instead of the
  interpreter. The wrapper now mirrors arg[-1], arg[-2], ... exactly.

math B is a genuine x64 JIT bug, not flaky/OOM: with -jon the random-stats
loops segfault (~0.02 s, RSS <7 MiB) or hang (>40 s), while -joff always
passes. Minimal repro tests/lib/math-jit-repro.lua: aux(1,32), aux(1,33),
aux(-10,10) (2.1-compatible, 13/20 failures). Bisect (with a git clean before each box build) puts the
first logical change at ad283709 "JIT: math.random on the 5.4 xoshiro state";
fcc6df4d is only the build repair for its math.modf dispatch-table mismatch.
A `-jdump=+rsi` crash dump shows the live trace calling lj_tab_newkey, with
the mcode post-call chain write; a core RIP maps to lj_tab_newkey:519
(`while (noderef(collide->next) != n)`) after a JIT table store. Known-bad
math B records this for Fable.
## Session 49 — FFI int64/uint64 and bit semantics vs native 5.4 integers

Queue item 2: three d54 tests (`ffi_int_01_arith`, `ffi_int_02_convert`,
`ffi_int_03_bit`, modes B,R; PUC has no ffi/bit so A skips) and
`docs/ffi-int-semantics.md`. The fork has no global `ffi` (use
`require("ffi")`); 8-byte cdata tostrings with LL/ULL, `math.type(cdata)` and
`math.tointeger(cdata)` are nil, `//` on cdata is unsupported, `bit.lshift/
rshift` are the names, `%d` on uint64 is signed, and bit.lshift/rshift/arshift/rol/ror are broken on arm64 (0 for both cdata
and native values, -joff and -jon alike; x64 correct; cause not yet located,
not merely a JIT fast path; not asserted in the portable test). Assertions were corrected
from measured behavior after the first pass was found vacuous (nil `ffi`
crashed all arms identically). No library/VM code change was needed. Gate:
ffi_int_* 6 PASS / 0 FAIL per box on arm64 and x86_64 (B,R).
## Session 50 — DIFFERENCES.md (docs-only)

`docs/DIFFERENCES.md` lists recorded, user-facing divergences only. Against PUC
Lua 5.4.9 there are 20 entries: FORK 2 (interning/%p identity, private dump
format); PENDING 6 (arbitrary `_ENV`, pcall/`__call` VM work, tail error names,
istailcall without hook, `lua_setcstacklimit`, >1 userdata values);
IMPL-DEFINED 4 (sparse-table border, table `__gc`, `__close` debug/yield
corners); EXTENSION 1 (`table.create`); plus seven known JIT/PERF rows (math
random, closure, heavy, arm64 bit shifts fixed, deltablue, spectral-norm,
k-nucleotide). Against stock LuaJIT 2.1 there are 10 entries: added 5.4
language/VM and stdlib/C-API surface, getfenv/setfenv kept, jit/bit/FFI/bcsave
kept, strict ASCII identifiers, FFI cdata semantics reference. Implemented
parity features are deliberately not listed. Sources: MISSION.md,
docs/phase0-status.md, tests/known-bad.tsv, docs/ffi-int-semantics.md.

## Session 51 — Fable bug dossiers: arm64 bit shifts and x64 math.random JIT

Prepared handovers only; no VM fix by this session. **Follow-up:** His fixed the
arm64 bit-shift bug in `6e4d7bb9` (checkint no longer clobbers TMP0;
`lj_carith_check64` accepts boxed ints and normalizes widened args; regression
`tests/lib/bit-checkint.lua`, gates green on both boxes). The dossier and
DIFFERENCES row are marked FIXED; the x64 math.random bug remains Fable-owned. `docs/bug-bit-shift-arm64.md`: arm64
`bit.lshift/rshift/arshift/rol/ror` return 0 for native and cdata in `-joff`
and `-jon` (all opt levels); first bad commit `cb2f6da` (checkint widened-range
test clobbers TMP0, which `.ffunc_bit_sh` uses for x); traced hot-loop BSHL is
correct, so `-jdump` shows no bad trace. `docs/bug-math-random-jit.md`: x64
`-jon` math.random stats SIGSEGV/hang, 13/20, first logical bad `ad283709`,
core RIP `lj_tab_newkey:519`, jdump trace included. Repros:
`tests/lib/bit-shift-repro.lua`, `tests/lib/bit-shift-trace.lua`,
`tests/lib/math-jit-repro.lua`.

## Session 52 — classic benchmark stage (stock 2.1 vs fork vs PUC 5.4.9)

Added `tests/bench/classic/` (pinned manifest, offline `.dlcache/bench`,
stock/PUC/fork arms, median of 3, serial box jobs; no benchmark fixes) and
`docs/bench-classic-2026-11-17.md`. Findings >10% slower than stock: arm64 —
deltablue 0.62x, scimark 0.90x, k-nucleotide 0.88x; x64 — spectral-norm 0.71x,
deltablue 0.69x, k-nucleotide 0.87x. No result-output differences in the
deterministic workloads; scimark rates not compared. richards/havlak sources
not available in the pinned set. Original table and method in the report file.

## Session 53 — classic benchmark regression diagnosis (no fixes)

`docs/perf-regression-2026-11-17.md`: deltablue's slowdown is trace loss from
`missing metamethod` aborts at `d:output().mark` (NOMM, lj_record.c:1876);
stock has none and forms a much larger loop trace. spectral-norm x64 is 5.4
integer loop arithmetic: ADDOV/SUBOV/MULOV guards + five int->num CONVs vs
stock's all-float loop. k-nucleotide x64 is slower in both `-jon` and `-joff`,
hot traces nearly identical; the cost is the table string-key GET miss with a
function `__index` (micro probe), not interning policy. arm k rerun at 6e4d is
faster (1.27), so that earlier row was noise; arm deltablue rerun improves to
0.76 but remains. x64 checkint still has the widened test but no bit/tobit
calls are in these hot traces. Diagnosis only; Fable owns fixes.

## Session 54 — x64 math.random JIT crash (known-bad math B) fixed

Root cause is not the key representation but an x64 register-width bug:
the checked `int64->int32` CONV (`lj_asm_x86.h` asm_conv, `movsxd; cmp; jne`)
left the sign extension in the result register, while `asm_href` and
`asm_tvptr` (NEWREF's `cTValue *key`) build the key word as
`(LJ_TISNUM<<47) | reg64`, assuming a zero-extended int32 register. A
negative `math.random(lo,up)` result used as a table key therefore became a
nil-tagged garbage key: HREF missed the interpreter's node, NEWREF inserted a
node whose `hashkey()` disagrees with its position, and the collision-chain
walk at `lj_tab_newkey:519` crashed or spun. Same family as `adc0eb97`
(snapshot restore). Positive ranges never failed (`aux(1,32)` 0/20);
`aux(-40,-1)` failed 20/20. arm64 is immune: its checked CONV ends in a
32-bit `mov` and `asm_tvstore64` uses `UXTW`.

Fix: the CONV re-materializes its result with a 32-bit `mov` (restores the
backend invariant for every consumer), and `asm_tvptr` writes an int32 key
as two 32-bit stores like ASTORE/HSTORE. Regression
`tests/lib/math-random-jit.lua` (ranges with negative keys, seeded, 20
rounds, plus a trace-stored/interpreter-read count) runs in ci-box under
`-joff`, `-O0`, `-O3` with a timeout; it fails on the unfixed tree and
passes after. Repro 50x at -O0 and -O3: 0 failures (before: 17/20 at -O3,
20/20 at -O0). Known-bad math B removed; `puc54/math.lua` mode B passes on
x64. Dossier updated with the root cause.

## Session 55 — bit.* hybrid rule for native 5.4 integers (branch `bit-hybrid`)

Review of `6e4d7bb9` (Fable) found that `lj_carith_check64` truncated widened
and boxed 5.4 integers to 32 bits and wrote them back, so a native int64 lost
its high bits even next to a 64-bit cdata (`bit.band(uint64 max, (1<<40)|0xff)`
→ `255ULL`), undocumented and inconsistent with the cdata path and with `&`.
Markus decided the hybrid rule (DIFFERENCES.md, ffi-int-semantics.md): pure-
number calls wrap modulo 2^32 (stock); a 64-bit cdata value operand promotes
native integers to their exact value; shifts/tohex decide by the value operand.
Commits: `941260e1` interpreter (`lj_carith_check64` returns the exact value,
`bit_narrow_args` narrows slots before `FFH_RETRY`, tohex masks, non-FFI
`bit_checkbit` normalizes), `9eaa36c2` JIT (`lj_opt_narrow_bitop`: TOBIT for
floats, `CONV int.i64` for widened/boxed; bit ffids admitted by the IRT_I64
gate in `lj_ffrecord_func`; `lj_opt_narrow_tobit` comment corrected — it serves
the 5.4 operators), `f4396401` tests (`bit-checkint.lua` pcall per row, hash
`cb2f6da2`, mixed rows, widened/boxed/float/mixed hot loops; ci-box `timeout`).
Measured on both boxes: `bit-checkint` green `-joff`/`-jon`; 24-input × 14-op
differential interpreter vs hot loop identical; `-jv` shows compiled traces for
widened, boxed, float and table-loaded operands (no `bad argument type`);
mixed-call output `-joff == -jon`; d54 `ffi_int_*`/`bits_*` 6/6. Gate
`tests/ci-box.sh` green on both boxes — arm64: A+B 114 PASS/5 XFAIL, B@0-3 244, R 61, GC-stress 59/1 XFAIL, jitutil 30 ok, corpus-ext 0 diffs, C API 112+14 checks 0 failures, fuzz 160/0; x86_64: the same numbers (114/5, 244, 61, 59/1, 30, 0 diffs, 112+14/0, 160/0).
Open: mixed calls with a native int64 operand run in the interpreter
(`crec_ct_tv` has no IRT_I64 source branch); a `-DLUAJIT_DISABLE_FFI` build
is not a supported configuration (its 5.4 operators are 32-bit:
`lj_meta_bitop` legacy path) although `bit.*` itself is correct there; the
`ULL` literal regression (`98f99180`) is DeepSeek's on main.

## Session 56 — `__index` regression item: alias-analysis miscompilation, io.lines, x64 checkint

Branch `jit-index-chain` (merged onto 2abfe5f5). Verified DeepSeek's two findings from Session 53
before changing code; both root causes turned out to be elsewhere than the
hypotheses said. Full account in `docs/perf-regression-2026-11-17.md`.

1. deltablue NOMM aborts (`lj_record.c:1876`): the recorder was right to abort
   -- the receiver of `d:output()` really was a constant nil in the IR.
   `removeFirst` does `local e = self.elms[#self.elms]`; `lj_opt_mem.c`
   (unchanged from stock) asks `irt_isnum(key)` to mean "this key may be an
   array index / change the length". With 5.4 integer hash keys as
   IRT_INT/IRT_I64 the NEWREF push `elms[#elms+1] = c` looked like a string
   key, so the ALOAD from the fresh TNEW was const-folded to nil (`-jdump=+a`
   shows `TNEW; NEWREF +1; HSTORE; ALEN; ASTORE nil` and no load). Same hole
   in `lj_opt_fwd_alen` (probe: `#t` after `t[4]=nil` with 4 in the hash
   part wrong in 2943/3000 iterations with -jon), `lj_opt_fwd_href_nokey`
   and the TDUP const-fold (an IR_KINT64 key went through lj_ir_kvalue as
   FFI cdata). Fix `56f9eea4`: `irt_isnumkey()` at the four sites,
   `aa_keytype()` (int64 box constant == IRT_I64 ref), KINT64 decoded as a
   5.4 integer. Test `tests/d54/jit_02_tabkey_alias.lua`. NOMM aborts 74 -> 0
   on arm, 0 on x64; deltablue x64 0.69x -> 0.83x.
2. k-nucleotide x64: not `__index`. The table GET miss with a function
   `__index` is at parity on both arches (micro + looped kernels). Two real
   costs: (a) `io.lines()` read a locked getc() per byte (5.4 NUL-safe lines),
   2x stock on 1 MB; `c62fa218` uses POSIX getline(), parity. (b) the x64
   `checkint` macro had grown a second mask/branch stage for the widened
   47-bit encoding. A one-compare form (`shr 32; cmp LJ_TISNUM<<15`, as
   arm64 does it) gains 12% on pure int loops but loses 20-25% on the
   string.sub/TGETV/TSETV paths k-nucleotide lives on (interleaved A/B, three
   rounds: f1 4.41 ms new / 3.47 old / 3.24 stock; perf-strkey K3 8.4 / 7.2 /
   6.4 ms) -- interpreter alignment, not instruction count. Reverted, not
   committed. In-process phase timings of k-nucleotide are at parity with
   -jon already; the whole-process
   difference is a constant ~11 ms outside the script (see open items).
3. deltablue residual (arm 0.73x after the fix): not `__index`, not code
   quality. Micro-benchmarks of every deltablue primitive are identical; the
   IR per recorded bytecode is identical (HLOAD .230/.237, HREFK .230/.238,
   guards .96/.99); table shape, bytes allocated and GC steps are within 5%;
   startup is +140 us. `-jp=v` says ours is 81% compiled vs stock's 61%, yet
   slower: the trace graph differs (ours roots at the chainTest loop :830 with
   the :720 loop unrolled inside, stock roots at :611/:720), and
   `-Ohotexit=5,tryside=8` closes most of the gap for ours only (0.85 -> 0.94).
   Linked side-trace entries bypass lj_trace_exit, so a trace-entry counter in
   the exit stubs is the next instrument. Left open.

Tools kept: `tests/lib/perf-*.py` from Session 53; the ad-hoc stats patch
(`newtab`/exit counters by vmstate) and the IR histogram script are described
in the regression doc, not committed.

Gate (arm64, escher, `sh tests/ci-box.sh` on c62fa218): A+B 116 PASS/0 FAIL/5 XFAIL (62 tests), opt 0..3 248/0, R 62/0, GC
stress 59+1X, jitutil smoke 30 ok, corpus-ext 15 arms SAME/0 unexpected, capi
112/0, i64 14/0, fuzz 160/0. Bench (`BENCH_ONLY=deltablue,k-nucleotide
BENCH_REPS=5`): deltablue stock 3561.5 / ours 4590.0 ms (0.78x; 0.76x before),
k-nucleotide stock 24.5 / ours 19.9 ms (1.23x). deltablue -jv: NOMM aborts
0 (74 before), traces 167 vs stock 163.
Gate (x86_64, pve2, c62fa218 plus the later-reverted checkint macro; re-run on
c62fa218 itself recorded below): R 62/0, GC stress 59+1X, jitutil smoke 30 ok,
corpus-ext 15 arms SAME/0 unexpected, capi 112/0, i64 14/0, fuzz 160/0 (A+B
and opt summaries in the follow-up job below). Bench: deltablue stock 20809.2 /
ours 24455.9 ms (0.85x; 0.69x before), k-nucleotide stock 63.0 / ours 72.5 ms
(0.87x; 0.86x before -- the remaining delta is the constant per-process cost
outside the script, see the regression doc). deltablue -jv x64: NOMM 0,
traces 167 vs stock 162.

Interpreter findings outside this item (micro `tmp/arith-micro2.lua`, -joff,
2e7 iterations): integer `%` is 6x slower than stock on both arches (arm
0.816 vs 0.136 s, x64 2.12 vs 0.36 s: a C helper per modulo); on x64 only, a
float add is 4.4x slower (0.614 vs 0.140 s) and an int64 accumulate 5x
(0.245 vs 0.048 s) because `ins_arith` sends every non-int32 operand to
vmeta_arith (arm64 has inline paths: 0.082 vs 0.079 / 0.033 vs 0.037 s).
Parser: `2147483647 + 1` folds to the float 2147483648.0 (lj_parse.c:862
foldarith stores an int-op-int result outside int32 as a float constant;
PUC and our runtime add give the integer). Not fixed here.
Final x64 gate on c62fa218 (checkint reverted): A+B 116/0/5 XFAIL, opt 0..3
248/0, R 62/0, GC stress 59+1X, jitutil smoke 30 ok, corpus-ext 15 SAME/0,
capi 112/0, i64 14/0, fuzz 160/0. Arm A+B 116/0/5, opt 248/0 likewise.
x64 per-process cost resolved: lua_close is ~13 ms in both (stock 93.6 -> 81.2
ms with os.exit(0,false), ours 96.7 -> 83.2); on a k-nucleotide-shaped script
ours is now +2-3 ms whole-process (-jon 75.3 vs 73.6 ms, os.exit 62.4 vs 63.0),
the in-script -joff part +6.7 ms (the ~8% interpreter cost per phase).

Final gate on the merge with main 2abfe5f5 (296202b0), both boxes identical:
A+B 117/0/5 XFAIL (63 tests), opt 0..3 252/0, R 63/0, bit-checkint ok,
math-random-jit OK, GC stress 59+1X, jitutil smoke 30 ok, corpus-ext 15
SAME/0, capi 112/0, i64 14/0, fuzz 160/0. Bench on that tree (REPS=5):
arm64 deltablue 3664.4 / 4399.9 ms (0.83x), k-nucleotide 17.8 / 19.4 ms
(0.92x, within the bimodal-box band); x86_64 deltablue 20534.1 / 24142.8 ms
(0.85x), k-nucleotide 66.3 / 73.1 ms (0.91x). deltablue -jv NOMM 0 on both
(arm ours 180 traces / stock 174, x64 181 / 173).

Review fixes (Fable, REQUEST CHANGES on one point): `783d5000` -- the same
IR_KINT64-key hole in `snap_unsink()` (lj_snap.c): a sunk store with a widened
int64 constant key was restored with lj_ir_kvalue, i.e. keyed by an FFI cdata;
`t[1099511627776] = i` under -O3 returned a cdata from next(t) and a full GC
without ffi loaded segfaulted. Decoded with lj_i64_toTValue like the slot
restore; `tests/d54/jit_03_sunk_i64key.lua` (positive, negative, TDUP) was
FAIL at B@3 before and passes A/B/opt 0-3 after. `efd5209e` hardens the
getline() reader (ENOMEM -> lj_err_mem, LJ_MAX_STR guard, string built from
the libc buffer and freed before the GC step). Merged origin/main d09eb089
(1352ab01); gate = ci-box + ci-local.sh --sanitizers-only, both boxes, numbers
below.
Gate on 1352ab01 (merge with main d09eb089), both boxes identical: ci-box A+B
121/0/5 XFAIL (66 tests), opt 0..3 264/0, R 66/0, bit-checkint ok,
math-random-jit OK, GC stress 59+1X, jitutil smoke 30 ok, corpus-ext 15
SAME/0, capi 112/0, i64 14/0, fuzz 160/0; `ci-local.sh --sanitizers-only`
187 PASS/0 FAIL/5 XFAIL (A,B,R), ci-local OK. Bench (REPS=5): arm64 deltablue
3662.9 / 4492.6 ms (0.82x), k-nucleotide 18.0 / 19.9 ms (0.90x); x86_64
deltablue 19885.6 / 24063.7 ms (0.83x), k-nucleotide 65.8 / 74.0 ms (0.89x).

## Session 57 — release fixes from the pre-release review (branch `release-jit-fixes`)

From `origin/release-candidate` 5a9ac048. Four items, four commits:
- `f0b84fde` parse: unary `~` on constants folded through `lj_num2bit`
  (modulo 2^32, no exactness): `~(2^40)` gave -1, `~(2^31)` 2147483647,
  `~2.5` -3, `~(2^63)` -1 (PUC: -1099511627777, -2147483649, error, error).
  Now folds only an exact integer operand whose `~` fits int32, like
  `foldbitop`; everything else is a runtime BC_BNOT. `expr_bitV()` removed
  (no other caller). `tests/d54/parse_fold_int.lua` extended; red in mode A
  before.
- `f78cc3b6` jit: the LJLIB_CF rewrites of type/rawlen/math.abs/floor/ceil
  had lost their LJLIB_REC, so the recorders were dead code (-Wunused) and
  every call stitched. Re-enabled with 5.4 result types: abs of an int32 is
  sign-specialised (GE guard / LT guard + SUBOV so -(-2^31) exits), of an
  IRT_I64 calls lj_i64_abs; floor/ceil pass integer refs through and convert
  a rounded float to int32 under a guard (NaN/inf/outside-int32 exit to the
  interpreter; a rounded value outside int32 at record time is not recorded).
  floor/ceil joined lj_ffrecord_funcs list of handlers that accept IRT_I64

## Session 57 — release fixes from the pre-release review (branch `release-jit-fixes`)

From `origin/release-candidate` 5a9ac048. Four items, four commits:
- `f0b84fde` parse: unary `~` on constants folded through `lj_num2bit`
  (modulo 2^32, no exactness): `~(2^40)` gave -1, `~(2^31)` 2147483647,
  `~2.5` -3, `~(2^63)` -1 (PUC: -1099511627777, -2147483649, error, error).
  Now folds only an exact integer operand whose `~` fits int32, like
  `foldbitop`; everything else is a runtime BC_BNOT. `expr_bitV()` removed
  (no other caller). `tests/d54/parse_fold_int.lua` extended; red in mode A
  before.
- `f78cc3b6` jit: the LJLIB_CF rewrites of type/rawlen/math.abs/floor/ceil
  had lost their LJLIB_REC, so the recorders were dead code (-Wunused) and
  every call stitched. Re-enabled with 5.4 result types: abs of an int32 is
  sign-specialised (GE guard / LT guard + SUBOV so -(-2^31) exits), of an
  IRT_I64 calls lj_i64_abs; floor/ceil pass integer refs through and convert
  a rounded float to int32 under a guard (NaN/inf/outside-int32 exit to the
  interpreter; a rounded value outside int32 at record time is not recorded).
  floor/ceil joined the lj_ffrecord_func list of handlers that accept IRT_I64
  arguments (that list aborted them with "bad argument type" first).
  `tests/lib/ffrec-54.lua` (ci-box lib check): root loop trace, no stitch
  trace, interpreter-equal results and math.type per builtin;
  `tests/d54/jit_04_ffrec_54.lua` for A/B/opt. Bench -jon (3e6 iterations,
  arm64): type 0.073 -> 0.020 s, abs 0.030 -> 0.002, floor 0.037 -> 0.002,
  rawlen 0.025 -> 0.001; `-jv` stitch traces 18 -> 0.
- `7edd8057` build: `#error` for LUAJIT_DISABLE_FFI (built, but 1 << 40 was
  256). The `#if LJ_HASFFI` blocks guard the FFI library itself, not dead.
- `bdffb38f` os: dead `os_checkdatefmt()` removed.

Gate on bdffb38f, both boxes identical: `-Wall` 0 warnings (GCC 13.3 arm64,
GCC 14.2 x86_64; GCC 16.1.1 in the aarch64 build container: 0 warnings, exit
0), ci-box A+B 125/0/5 XFAIL (68 tests), opt 0..3 272/0, R 68/0,
bit-checkint ok, ffrec-54 ok, math-random-jit OK, GC stress 59+1X, jitutil
smoke 30 ok, capi 112/0, i64 14/0, fuzz 160/0; `ci-local.sh
--sanitizers-only` ci-local OK (198 jobs A,B,R). corpus-ext ran 0 arms in
that pass (the fresh worktree had no .dlcache); rerun separately, result
below.
corpus-ext rerun with .dlcache present: 15 arms SAME / 0 unexpected on both boxes
(the three known IMPL-DEFINED pairs()-order diffs only).
