# LuaJIT-5.4 — master execution plan

Companion to `MISSION.md`. Tracks every phase as concrete tasks with
dependencies, verification gates and status. Read `docs/phase0-status.md` for
environment/repo facts. **Rule: no task is done until the harness is green and
the change is committed with a phase-labeled message.**

Legend: `[x]` done · `[~]` in progress · `[ ]` open · `(dep: …)` blocking dependency.

## Status snapshot (see docs/phase0-status.md for the session log)
Verification: d54 **PASS 71 / XFAIL 19 / FAIL 0** (30 files); full corpus
**PASS 115 / XFAIL 36 / SKIP 12 / TIMEOUT 2 / FAIL 0**; C API harness **34/34**;
mode-B differential fuzz green at opt levels 0–3 with GC pressure.
Done: Phase 0 (harness/fuzzers/CI), and large parts of Phase 1 (lexer/scanner
int-float split, parser float constants + `<const>` + goto diagnostics, table
borders, `__len`/`__pairs`/`__name`, error messages, C API) and Phase 5 (utf8,
string.pack, `%q`, gmatch, os/io, debug upvalues, math.type/tointeger/ult).
**Critical blocker: ADR-001 (int64 value model).** Everything numeric beyond
int32+double — `//`, int64 bitwise, math.maxinteger, exact large-int
arithmetic/compare, 5.4 dump format — depends on it. Also open: `<close>` /
coroutine.close, generational GC + table `__gc`, `_ENV`, and UBSan cleanliness.

---

## ADR-001 — value model (the critical architectural decision)

**Finding (verified in-tree):** LuaJIT 2.1's dual-number mode stores integers as
**`int32_t`** (`lj_obj.h`: `TValue.i`, `intV`, `setintV`; `setint64V` demotes to
int32 or double). `TValue` is **8 bytes** with NaN-boxed tags:

* `LJ_GC64` (x64/arm64 default): 47-bit payload + 17-bit tag in one u64.
* non-GC64: 32-bit value + 32-bit tag.

**There is no room for a 64-bit integer plus a tag in 8 bytes.** MISSION §5's
"keep the JIT's existing register model" is fine for the *IR* (values live in
registers), but the *interpreter* cannot represent Lua 5.4 integers exactly
without a wider value slot. This is the single biggest structural change of the
port and the root dependency for Phases 1–3.

Options considered:

| option | exact int64 | invasiveness | verdict |
|---|---|---|---|
| keep 8-byte TValue, ints ≤2^53 only | no | none | rejected: breaks 5.4 |
| box large ints in a GC object | yes | high (value semantics everywhere) | rejected |
| split value/tag arrays (PUC-style) | yes | very high (rewrites all type dispatch) | rejected |
| **16-byte TValue: NaN-boxed low word + int64 in high word, new tag `LJ_TISNUM64`** | yes | high but mechanical | **chosen** |
| 16-byte TValue, PUC-style split tag | yes | very high | fallback only |

**Chosen design (ADR-001a):**
* `TValue` becomes 16 bytes (`LJ_TVSZ 16`, `LJ_TVSH 4`). Low 8 bytes keep today's
  NaN-boxed encoding for *all* existing types (nil/bool/str/func/tab/…/double).
* New internal tag `LJ_TISNUM64` in the low word; the full `int64_t` lives in the
  high word (`o->i64`). `tvisint()`/`intV()`/`setintV()` move to it.
* `LJ_DUALNUM` is forced on for all targets (5.4 requires the int/float split).
* Stack slots double: every `BASE+R*8` → `BASE+R*16` (x64/x86),
  `BASE, R, lsl #3` → `lsl #4` (arm/arm64), PPC equivalents. Register-save areas
  and other `*8` uses must NOT change — this is the main risk.
* C side mostly uses `sizeof(TValue)` already (22 sites) plus `tvref` arithmetic.
* Snapshots (`lj_snap.c`) restore TValues → must write 16 bytes and the int64 tag.
* IR: add `IRT_I64` as a first-class type (MISSION's `IRT_INT64`), keep `IRT_NUM`.

**Migration order (keeps the tree buildable):**
1. `LJ_TVSZ`/`LJ_TVSH` constants + `TValue` union + accessors (C only, compiles).
2. C users of hardcoded slot sizes (`lj_state.c`, `lj_func.c`, `lj_tab.c`, …).
3. VM assembly per backend, **arm64 first** (native, testable here), then x64
   (primary CI), then x86/arm/ppc/mips.
4. Snapshot/restore + JIT stack layout.
5. Only then: 5.4 arithmetic semantics (P1.4) and IR int64 (P2).

Until step 3 lands for an arch, that arch cannot run the 5.4 interpreter; the
harness is run on arm64 (native) and x64 (CI).

---

## Phase 0 — verification harness (M0)  `[x]`
See `docs/phase0-status.md`. Baseline: PASS 82, XFAIL 39, SKIP 12, TIMEOUT 2,
FAIL 0, BAD 0; ASan+UBSan build clean on `tests/d54`.
Remaining polish: `[ ]` per-test timeout overrides for `heavy.lua`/`calls.lua`;
`[ ]` full-corpus ASan run; `[ ]` mneme persistence of decisions.

## Phase 1 — lexer, parser, bytecode, interpreter (M1)
Gate: **mode A fully green** (interpreter ≡ PUC 5.4.7), dump round-trip normalized.

* `[ ]` **P1.1 value model** — ADR-001 steps 1–4. (dep: none; blocks P1.4, P2, P3)
* `[ ]` **P1.2 lexer** (`lj_lex.c`, `lj_strscan.c`): 5.4 numeral grammar — decimal
  int vs float, hex ints, hex floats, overflow→float, `1.`/`.5`, malformed-number
  messages. No underscores, no `0b` (verified). Tests: `lex_01_literals.lua`,
  upstream `literals.lua`.
* `[ ]` **P1.3 parser/bytecode** (`lj_parse.c`, `lj_bc.h`, `lj_bcread.c`,
  `lj_bcwrite.c`): tokens `// & | ~ << >>`, 5.4 precedence table, `<close>`/
  `<const>` attributives, goto/label 5.4 scoping, `OP_IDIV/OP_BAND/…`, int
  constants via EXTRAARG, 5.4 dump header + strip. Tests: `goto_01_labels.lua`,
  `numeric_03_idiv.lua`, `bits_01_ops.lua`, upstream `constructs.lua`.
  **NOTE:** bitwise BC ops (BNOT/BAND/BOR/BXOR/BSHL/BSHR/BSAR), IR ops, recorder
  and all backends ALREADY EXIST in 2.1 (int32 semantics via lj_num2bit) — the
  task is to change semantics to int64/5.4, not to add infrastructure. `//`
  (IDIV) is the only genuinely new arithmetic op.
* `[ ]` **P1.3b table borders** — replicate PUC `luaH_getn` in `lj_tab_len`
  (5.4 `#` returns 3 for `{1,nil,3}`, 2.1 returns 1). Fixes `table.concat`,
  `table.unpack`, `#{...}` diffs. Also fix the dump/reload template-table
  inconsistency found by mode R (`tests/d54/dump_02_border.lua`): the same
  source gives border 1 direct and 3 after `string.dump`→`load`.
* `[ ]` **P1.8 error messages** — LuaJIT reports `bad argument #1 to '?'` when a
  library function is called without a name context (e.g. `pcall(table.move,…)`);
  PUC resolves `table.move` by searching globals/upvalues. Port PUC's
  `getobjname`/`funcnamefromcode` name search into `lj_debug.c`/`lj_err.c`.
* `[ ]` **P1.4 interpreter semantics** (`lj_vm*.dasc`, `lj_meta.c`, `lj_vmmath.c`):
  int64 wrap arithmetic, `//` floor, `%` sign rules, `^`→float, bitwise with
  exactly-representable floats, mod-64/negative shifts, exact int↔float compare,
  10-way metamethod operand matrix, `__len` any value, `__pairs` ignored,
  `error(level)`/error objects, vararg, concat. Tests: all `numeric_*`, `bits_*`,
  `meta_*`, `err_01`, upstream `math.lua`, `bitwise.lua`, `vararg.lua`.
* `[ ]` **P1.5 to-be-closed** (`<close>`, `__close`, `coroutine.close`): VM close
  handling, coroutine close, error-path ordering. Tests: `gc_01_tbc_gc.lua`,
  `coro_01_close.lua`.
* `[~]` **P1.6 C API surface** (`lj_api.c`, `lauxlib.c`, `luaconf.h`, `lua.h`):
  DONE: `lua_absindex`, `lua_isinteger`, `lua_geti`, `lua_seti`, `lua_len`,
  `lua_compare`, `lua_stringtonumber`, `luaL_len`, `luaL_getsubtable`
  (29-check C harness `tests/capi/`, all green).
  TODO: `lua_Integer`→int64 exactness (dep: P1.1), `lua_pushvfstring` audit,
  `lua_gc` 5.4 actions, version strings, `lua_arith`, `lua_getiuservalue`,
  `lua_setiuservalue`, `lua_newuserdatauv`, `lua_warning`.
* `[ ]` **P1.7 number formatting/parsing** (`lj_strfmt*.c`, `lj_strscan.c`):
  `%.14g` rendering, `%d` integer-representation rule, `%a`, `%q` for numbers,
  `tonumber` bases/hex/whitespace. Tests: `fmt_01_format.lua`, `lex_01_literals.lua`.

## Phase 2 — IR int domain (M2)
Gate: mode B green for `numeric*`, `bits*`, `metamethod*`; no interpreter changes.
* `[ ]` P2.1 `IRT_I64` type + `IR_*` int ops (`lj_ir.h`, `lj_ir.c`). (dep: P1.1)
* `[ ]` P2.2 int↔float `IR_CONV` with 5.4 rules; literal int64 IR; exact folding.
* `[ ]` P2.3 domain propagation: prove integer-ness only where the interpreter
  guarantees it; explicit coercions where bytecode forces them.
* `[ ]` P2.4 metamethod guard model: snapshot predicates for "operand is integer",
  10-way dispatch matrix reproduced exactly (`lj_record.c`, `lj_snap.c`).

## Phase 3 — optimizer + backends (M3)
Gate: harness green at opt levels 0–3, ≥10M fuzz programs, all backends.
* `[ ]` P3.1 5.4-exact folds, overflow-aware (`lj_opt_fold.c`, `lj_opt_*.c`).
* `[ ]` P3.2 register allocation for int64 in the 64-bit class (`lj_asm.c`,
  `lj_regalloc.c`, `lj_snap.c`).
* `[ ]` P3.3 backends: x64 → x86 → arm64/arm → ppc/mips. `idiv` floor correction,
  int mod sign correction, mod-64 shifts, logical `>>`, wrap codegen.
* `[ ]` P3.4 deopt correctness: int/float tags restored exactly (deopt fuzz).

## Phase 4 — GC and strings (M4)
Gate: GC-fuzz mode green, ASan/LSan clean.
* `[ ]` P4.1 generational GC 5.4 (minor/major, `collectgarbage` args, step counts).
* `[ ]` P4.2 weak tables + `__gc` resurrection/finalizer rules, cycles.
* `[ ]` P4.3 string interning/buffer tricks audited vs 5.4 GC timing; `lj_strfmt`
  float formatting per 5.4.
* `[ ]` P4.4 `lua_gc` actions, GCpause defaults, LSan leak checks.

## Phase 5 — standard libraries (M5)
Gate: PUC 5.4 suite green in mode A; mode B green; per-library sign-off.
Independent of the numeric core (can proceed in parallel):
* `[ ]` P5.1 `utf8` (new `lj_lib_utf8.c` or `lib_utf8.c`). Tests: `utf8_01_lib.lua`.
* `[x]` P5.2 `string.pack/unpack/packsize` — implemented in `lib_string.c`
  (adapted from 5.4.7 reference); `str_02_pack.lua` matches PUC except the
  P1.8 function-name issue.
* `[~]` P5.3 `table.move/pack/unpack(i,j)/concat` 5.4 — `table.move` and
  `table.unpack` implemented with metamethod-aware `lua_geti/lua_seti`;
  `table.pack` ungated from LJ_52. Remaining: `#` border algorithm (P1.3b).
* `[ ]` P5.4 `string` lib 5.4 (`rep` sep, `format`, patterns). Tests: `dump_str_01.lua`, `pm.lua`.
* `[ ]` P5.5 `math` 5.4 (`type/tointeger/ult/maxinteger/mininteger`, random). (dep: P1.1)
* `[ ]` P5.6 `os`/`io` 5.4. Tests: `math_os_01.lua`, `files.lua`.
* `[ ]` P5.7 `coroutine` 5.4 (`close`, error messages). (dep: P1.5)
* `[ ]` P5.8 `debug` 5.4 (`upvalueid`, `info` fields, hooks). Tests: `db.lua`, `closure.lua`.
* `[ ]` P5.9 `package`/`require` 5.4. Tests: `attrib.lua`.
* `[ ]` P5.10 FFI re-validation against the new value type (every phase).

## Phase 6 — hardening + release (M6)
* `[ ]` P6.1 30-day coverage-guided fuzzing (interpreter + JIT), differential both ways.
* `[ ]` P6.2 perf sanity (JIT ≫ interpreter), int-path report.
* `[ ]` P6.3 docs: what's 5.4 vs LuaJIT-specific; MANIFEST-level.
* `[ ]` P6.4 tarball + release notes.

---

## Working agreements
* Tests before code (MISSION §7.2); every §4 box maps to a test in `docs/54port.md`.
* Keep the tree buildable and the harness green at every commit; use
  `tests/known-bad.tsv` to record expected failures, never to hide regressions.
* Long runs: background + poll, or `timeout N`. Never two harness runs at once.
* Commit messages: `Phase N (Mx): <task> — <what/why>`.
* Deviations from MISSION are recorded in `docs/phase0-status.md` (errata) and
  here (ADRs), never silently.
