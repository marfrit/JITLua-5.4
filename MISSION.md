# MISSION: LuaJIT 5.4 — a maintained JIT compiler for the Lua 5.4 language

Status: public release preparation. Lua 5.4 language and C API port implemented and differentially gated on Linux arm64/x86_64; current gates A+B 115 PASS / 0 FAIL / 5 XFAIL, optimization levels 248, R 62. Remaining divergences and known gaps are tracked in docs/DIFFERENCES.md and tests/known-bad.tsv.
Date: 2026-11-14
Base: LuaJIT 2.1 (official tree, `https://github.com/LuaJIT/LuaJIT`, tag v2.1)
Target language/ABI: PUC-Rio Lua 5.4 (5.4.4/5.4.7 semantics)

---

## 1. Mission statement

Deliver **LuaJIT 5.4**: the LuaJIT 2.1 JIT compiler ported so that it fully
implements the Lua 5.4 language and the Lua 5.4 C API (source- and ABI-
compatible), with a verification harness that proves the JIT is correct against
the reference interpreter.

Strategic decisions (fixed):

- **Build on the LuaJIT 2.1 tree.** The optimization passes, register
  allocator, and x86/x64/ARM/PPC backends are the crown jewels; they are
  largely language-version-independent and survive the port.
- **Do not adopt unfinished 5.2/5.3 forks as a base.** They are used as
  *reference material only* (ideas, diffs). Known prior art to study, not to
  inherit:
  - `sthalik/luajit` + fperrad `tiny_fork` branch (5.2/5.3 compat work,
    some merged upstream)
  - `thenumbernine/lua-ffi-wasm` (runs stock Lua 5.4.7 with "small
    modifications for LuaJIT parsing compatibility" — evidence that the
    frontend port is tractable)
  - `Legacy-LuaSTG-Engine/LuaSTG-Sub-LuaJIT` (backports utf8 lib,
    string.pack/unpack into 2.1)
- **Verification is the mission's real success criterion.** Every phase ends
  green on the differential test harness (Phase 0), never on "looks right".

## 2. Goals

1. Correct 5.4 language semantics: int/float numeric model, bitwise ops,
   `//`, floor-modulo, 5.4 comparison/metasemantics, goto/label, 5.4
   string/format/tonumber behavior, utf8 lib, updated table/os/math libs.
2. A JIT that compiles 5.4 programs with a correct int/float domain model in
   the IR, optimizer, and all four backends.
3. 5.4-compatible C API (incl. removal of `luaL_Buffer`-style legacy APIs,
   `luaL_len`, `lua_stringtonumber`, `lua_pushvfstring`, etc.).
4. Differential verification: PUC-Lua 5.4.7 ≡ our interpreter (jit.off)
   ≡ our JIT (jit.on), with fuzzing kept permanently green.
5. Clean, staged delivery; each milestone independently demonstrable.

## 3. Non-goals

- LuaJIT-specific extensions are *kept*, not removed (FFI, `jit.*`,
  `bit.*`, profile hooks). Where they conflict with 5.4, the extension
  behavior wins but 5.4 builtins must be correct.
- Lua 5.5 / Luau.
- New backends. Existing backends only.
- Performance parity or beating PUC-Lua — correctness first, performance
  second (no silent deoptimization beyond what the int/float model forces).

## 4. Scope of semantic delta (5.1 → 5.4)

Checklist of everything that changes. Each item must have at least one test
in the harness by the end of the phase that implements it.

### 4.1 Numeric model (the core of the port)
- [ ] Two number types: `integer` (signed 64-bit, arithmetic wraps mod 2^64),
      `float` (IEEE-754 double).
- [ ] `+ - * /` on ints stay ints (wrap); on floats stay floats; mixed
      pairs coerce int→float (except overflow → float).
- [ ] `//` (idiv): integer floor division for ints; float floor division
      for floats/mixed.
- [ ] `%` (mod): integer result for ints (sign = divisor's); float result
      otherwise (sign = dividend's).
- [ ] `^` (pow): float result always (5.4: `^` on ints returns float).
- [ ] Unary minus: int negation for ints, `0-x` for floats.
- [ ] Bitwise: `& | ~ << >>` — integer-only, errors on floats (with
      `__` metamethod fallback for mixed operands).
- [ ] Metamethod matrix: `__add __sub __mul __div __idiv __mod __pow
      __band __bor __bxor __shl __shr __bnot` with all
      int/float/int-metamethod operand combinations (5.4 spec table).
- [ ] Comparisons: `__eq __lt __le` for int↔float pairs (numeric compare is
      exact cross-type; metamethods apply when types differ and no
      metamethod exists → numeric comparison).
- [ ] int→float conversion truncates (5.4; 5.3 rounded) — affects
      `tonumber`, conversions, `math.*` boundary cases.
- [ ] `tonumber`: 64-bit ints, `0x`/`0b`/`0X`, underscores between digits,
      `08`/`09` legal, float parsing.
- [ ] `math` library: 5.4 split (integer-oriented vs float-oriented),
      `math.type`, `math.tointeger` (5.3+), `math.random`/`math.randomseed`
      5.2+ semantics, `math.huge` vs `math.huge`/inf handling.

### 4.2 Language / syntax
- [ ] `goto` / `::label::` (already in 2.1 — align with 5.4 rules: labels
      as first/last statement, goto scoping rules).
- [ ] `...` (vararg) semantics per 5.4 (including `#...`).
- [ ] `string.format`: 5.4 `%g` (shortest round-trip representation),
      `%d` accepts float only when exactly integer-valued, `%x %X %o %i`
      integer-only, `%a` (5.3+), padding/width rules.
- [ ] `string.rep`, `string.sub`, `string.find` patterns: 5.4 exact rules.
- [ ] `table.unpack` with i/j, `table.pack`, `table.move`, `table.create`
      (5.4).
- [ ] `__len` may return any number (5.4), `#` semantics on tables with
      non-integer `__len` results.
- [ ] `__pairs`/`__ipairs` do **not** exist (5.2 removed them).
- [ ] `utf8` library: `utf8.char utf8.codes utf8.len utf8.offset
      utf8.charpattern` (5.3+).
- [ ] `coroutine.close` (5.4), coroutine resume/yield error-message
      semantics.
- [ ] `string.pack`/`string.unpack` 5.3+ syntax: `=` default, no
      endianness/align chars other than `>` `<`, `J L j l` 64-bit specs,
      5.4 `s0`/`z`/`c0` exactness.
- [ ] `os.time(os.date(...))` table argument (5.4), `os.difftime`,
      `os.clock` unchanged.
- [ ] `io` library: 5.4 exactness (seek, lines, strict number conversion in
      `io.lines`? no — keep 5.4 spec: `io.lines`/`read` number format).
- [ ] `xpcall` error-object semantics, `error(level)`.
- [ ] Environment: 5.2+ `getfenv/setfenv` removed from standard library
      (LuaJIT 2.1 exposes them as extensions — keep as extensions, document).

### 4.3 VM / bytecode
- [ ] 5.4 opcode set: `OP_EXTRAARG`, `OP_NI`, `OP_IDIV`, `OP_MOD` (float),
      `OP_POW`, `OP_BAND/OR/XOR/SHL/SHR`, `OP_FORI` (int-only), `OP_FORN`
      (float), `OP_TAILCALL` vararg forms, `OP_GETTABUP/GETTABLE/SETTABUP/
      SETTABLE` with A as pseudo-register (5.2+ layout), `OP_CONCAT`
      3-register variadic (5.2+), `OP_FORPREP/FORLOOP` removed,
      `OP_VARARG` → `OP_VARG`.
- [ ] Constant handling: `OP_LOADK/LOADKX/LOADI` int constants up to 64-bit
      via EXTRAARG; floats via constant table.
- [ ] `string.dump`: 5.4 header format, int constant serialization,
      `strip` flag.
- [ ] Upvalue/close semantics (`OP_TBC`? no — `OP_CLOSE`), 5.4 upvalue
      rules unchanged from 5.2.
- [ ] C API: `luaL_Buffer`-style legacy APIs gone (use `luaL_add*`/
      `luaL_pushresult` + `lua_pushvfstring`), `luaL_len`, `luaL_getmetafield`,
      `luaL_getsubtable`, `lua_absindex`, `lua_stringtonumber`, `lua_newstate`
      `Lua 5.4 header` version strings, `LUA_OK/LUA_ERRMEM` etc. unchanged,
      `lua_gc` 5.4 actions (`LUA_GCGENINC`, step behavior), `lua_sethook`
      line-hook opcode numbers per 5.4.

### 4.4 Garbage collector
- [ ] 5.4 generational GC: minor/major split, `collectgarbage("generational",
      minormajorstep, majorstep)`, incremental `LUA_GCINC` step semantics
      (5.4 changed what "step" counts).
- [ ] 5.4 weak-table behavior (weak values resurrection rules),
      `__gc` finalization of objects with finalizers, `__gc` + cycles.
- [ ] String interning/concatenation GC integration (see Phase 4 —
      LuaJIT's string-buffer tricks must survive 5.4 GC timing).
- [ ] Light userdata, userdata `__gc`, metatable `__mode` exact 5.4 rules.

## 5. Architecture notes (what is reused vs. changed)

| Component | 2.1 status | 5.4 action |
|---|---|---|
| Lexer/parser `lj_lex.c lj_parse.c` | 5.1+goto+FFI | Extend: int literals, 5.4 grammar corners, utf8 source |
| Bytecode `lj_bc.h lj_bc.c lj_bcdef.h` | 5.1 set | Replace opcode set with 5.4, new instruction layouts |
| Interpreter `lj_bc.c` `lj_strfmt_*` | 5.1 semantics | Reimplement numeric ops, bitwise, int/float paths |
| IR core `lj_ir.c` | float-centric IR | **New:** int type in IR, new IR ops (BIT ops, IDIV, IADD…), domain tracking |
| Optimizer `lj_opt_*.c` | float peephole | **New:** int/float domain propagation, overflow-aware folds |
| FOLD specializations `lj_snap lj_cdata` | — | Extend for int types |
| Register alloc `lj_snap.c lj_alloc*` | OK | Small changes for wider value class |
| Backends `lj_*.c` (x64 x86 arm ppc) | float codegen | **New:** int op encodings, 64-bit int ops, wrap/overflow codegen |
| GC `lj_alloc.c lj_tab.c lj_str.c` | 5.1 GC | Align with 5.4 generational GC + weak/finalizer rules |
| String handling `lj_str.c lj_strfmt_*` | LuaJIT tricks | Keep tricks, fix 5.4 format/parse semantics |
| FFI `lj_ffi_*` | LuaJIT extension | Keep; rebase on new value type (int64 is native — mostly OK) |
| C API compat `lua_*` glue | 5.1 ABI | **New:** 5.4 API surface + conversion between tagged values and 5.4 types |

Key design decision — **value model**: LuaJIT 2.1 on 64-bit already stores
numbers as 64-bit quantities (softfp doubles in registers). Introduce a
first-class 64-bit integer type in the IR (e.g. `IRT_INT64` alongside
`IRT_NUM`), keep the JIT's existing register model, and let domain
propagation in the optimizer explain *when* a value is known-integer. Rule:
the interpreter is the oracle; the JIT must reproduce its exact
int/float/wrap/coerce/metamethod behavior, bit for bit.

## 6. Phases and milestones

Every milestone ends with the full Phase-0 harness green.
Definition of done for *any* code change: `harness.sh` passes in both modes.

### Phase 0 — Verification harness (M0)
Deliverables:
1. Test runner `tests/harness.sh`:
   - **Mode A (interpreter correctness):** run corpus with `--jit=off`
     against a parallel PUC-Lua 5.4.7 build; compare results and error
     strings (whitespace-normalized), `string.dump` output normalized.
   - **Mode B (JIT correctness):** run corpus in the same binary with
     `--jit=on` vs `--jit=off`; full comparison.
2. Corpus: PUC-Lua 5.4 test suite (adapted), LuaJIT 2.1 test suite
   (subset still meaningful), new `tests/d54/` edge-case files written
   per section of §4 (each checklist item ≥ 1 test).
3. Fuzzer: Lua source fuzzer (mutate valid 5.4 programs; generate random
   int/float constants, metamethod tables, GC pressure via
   `collectgarbage("step")` interleave, `jit.opt.level` 0–3,
   `jit.vmtime`? no — use `jit.profile` off; seed-able, reproducible).
   Also a **dump-reload fuzzer**: `string.dump` → reload → re-run, to
   exercise the serializer.
4. CI: all of the above on x64 Linux (primary) + x64 Windows (build check),
   with ASan+UBSan builds of the interpreter and JIT.
Acceptance (M0): harness runs, corpus fails *as expected* on unported
2.1 (known-bad list recorded), ASan build clean.

### Phase 1 — Lexer, parser, bytecode, interpreter (M1)
Tasks:
1. Lexer: int vs float literal classification per 5.4 (`0x`, `0b`,
   underscores, `1e10`, `1.`, `.5`, hex floats), utf8 source decoding.
2. Parser: 5.4 grammar alignment (goto already present; validate label
   rules, `//` precedence, `& | ~ << >>` precedence vs. comparisons).
3. Bytecode: new `vmdef.x86`/`vmdef.arm`/`vmdef.ppc` opcode tables for
   the 5.4 set; constant encoding (int32/64 via EXTRAARG, float table).
4. Interpreter: full reimplementation of numeric semantics per §4.1,
   table ops with pseudo-register A, `OP_FORI`/`OP_FORN` loop bodies,
   concat, vararg, closure/upvalue/close per 5.4.
5. C API: grow the compat layer to the 5.4 surface (§4.3 list).
Acceptance (M1): **Mode A fully green** — the interpreter is a correct 5.4
implementation; `string.dump` round-trips with PUC-Lua (normalized).
This is the big, testable wall; the JIT is not touched yet.

### Phase 2 — IR: int domain (M2)
Tasks:
1. New IR type `IRT_INT64` (64-bit signed, wrapping) + `IRT_NUM` retained.
2. New IR ops: `IR_ADD/IR_SUB/IR_MUL/IR_DIV` (int variants), `IR_IDIV`,
   `IR_MOD` (float) vs int mod, `IR_BAND/BOR/BXOR/SHL/SHR`, `IR_NOT`
   (bitwise), `IR_BAND` etc. with 5.4 operand semantics; `IR_CONV`
   int↔float (truncating) and `IR_TONUM/TOINT`-style conversions with
   5.4 rounding rules.
3. Literal IR ops: `IR_LIT` int64 variants; constant folding 5.4-exact.
4. Domain propagation: values are `NUM` by default; integer-typed
   literals/loads produce `INT64`; coercions emitted explicitly where the
   bytecode forces them (e.g. `FORN`), so the JIT can *prove* integer-ness
   only where the interpreter guarantees it.
5. Guard model for metamethod dispatch: JIT-compiled `OP_ADD` etc. must
   reproduce the interpreter's exact dispatch (direct op → `__add` with
   5.4's operand-type-driven selection), including the 10-way int/float
   operand matrix.
Acceptance (M2): `--jit=on` green for all of `tests/d54/numeric*`,
`tests/d54/bits*`, `tests/d54/metamethod*`; ASan clean; no interpreter
changes in this phase.

### Phase 3 — Optimizer and backends (M3)
Tasks:
1. Peephole/fold passes: 5.4-exact folds (e.g. `x+0` only when
   x provably int or float; `(x//1)`; bitwise identities only for int;
   overflow-aware: no fold that changes wrap behavior).
2. Register allocator: int64 values in the same register class as NUM
   (64-bit); no new classes, but allocation counts widen.
3. Backends (x64 first, then x86, ARM, PPC): int64 op encodings
   (add/sub/mul/shl/shr/and/or/xor), `idiv` (x64: `cqo/idiv` + floor
   correction for negatives), int mod (5.4: sign = divisor's → not the
   hardware `idiv` remainder — needs correction), 64-bit shifts with
   5.4's "shift count & 63 / negative-count error" rules, `tonumber`-
   path convs, float code retained.
4. Snapshot/record for metamethod guards (`lj_snap.c`): guard on
   "operand is integer" must be a real snapshot predicate.
5. Deopt correctness: any deopt path must restore the exact
   interpreter value state (int/float tags included).
Acceptance (M3): full harness green at `jit.opt.level` 0, 1, 2, 3 and
`--jit=off/on` equivalence across all of `tests/d54/` and the fuzz corpus
(≥ 10M generated programs, 0 failures), all backends on their CI archs.

### Phase 4 — GC and strings (M4)
Tasks:
1. Generational GC to 5.4 behavior: minor/major, pauses, `step`
   semantics; weak-table and finalizer (`__gc`) rules per §4.4.
2. String interning and the LuaJIT string-buffer/concat tricks audited
   against 5.4 GC timing and `string.format`/parse semantics; fix
   wherever 5.4 changed observability (e.g. format `%g` shortest
   representation — reimplement `lj_strfmt.c` float formatting per 5.4).
3. `lua_gc` API actions, `collectgarbage` args, `GCpause` defaults
   (5.4: 100), 5.4 weak-value resurrection corner.
Acceptance (M4): harness green including a dedicated GC-fuzz mode
(random `collectgarbage("step")`, `"generational"` toggles, finalizer
storms, weak-table mutation); ASan/LSan clean (no leaks: 5.4 finalizer
semantics must not leak objects 2.1 didn't).

### Phase 5 — Standard libraries (M5)
Tasks: full 5.4 `table, string, utf8, math, os, io, coroutine, package,
debug` (debug lib: 5.4 `debug.gethookcount`, exact `info` fields);
C module loader unchanged; `ffi` kept and re-validated against the new
value type.
Acceptance (M5): PUC-Lua 5.4 test suite green in Mode A; Mode B green;
library-by-library sign-off table filled in.

### Phase 6 — Hardening and release (M6)
Tasks: 30-day continuous fuzzing with coverage feedback (AFL/libFuzzer
on the interpreter *and* the JIT via `--jit=on`), differential mode both
ways; performance sanity check (JIT still 10–100× interpreter; report
int-path performance), documentation (`MANIFEST`-level doc: what's 5.4,
what stays LuaJIT-specific), tarball + release notes.
Acceptance (M6): zero open harness failures; fuzz dashboard green for
30 consecutive days; perf report attached.

## 7. Verification rules (non-negotiable)

1. **Never** mark a phase done without the full harness (both modes)
   green on the current corpus.
2. Every new semantic item in §4 lands with ≥1 regression test in
   `tests/d54/` *before* its code.
3. Fuzz seeds that ever fail are committed to the corpus (reproducible).
4. Interpreter is the oracle: JIT bugs are fixed in the JIT; if the
   interpreter is wrong, that's a Mode-A bug first.
5. ASan+UBSan builds run in CI on every commit; 5.4 finalizer/weak-table
   changes are LSan-checked (leaks are the classic GC-port bug).
6. `string.dump` round-trip is a first-class test: every program in the
   corpus must dump, reload, and re-execute identically.

## 8. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| int/float domain propagation gets a corner wrong (e.g. overflow at fold time) | High | Mode-B differential fuzzing with GC+opt-level variation; overflow test matrix |
| 5.4 int mod/idiv floor semantics vs. hardware remainder | High | Dedicated idiv/mod tests incl. INT64_MIN/-1 (wrap!), negatives |
| LuaJIT string-buffer tricks break under 5.4 GC timing | Medium | Phase 4 audit; GC-fuzz mode |
| Metamethod dispatch matrix (10+ operand combos × 11 operators) missed | High | Generated tests: cartesian product of operand types × operators × metamethod presence |
| Deopt/snapshot loss of int/float tag | Medium | Deopt fuzz: force deopts mid-numeric-expression via memory pressure / type change |
| Scope creep into "fix all LuaJIT" | Medium | Non-goals list (§3) enforced at review |
| FFI rebase surprises on value type | Low-Med | FFI regression suite runs every phase, not just M5 |
| Backend divergence (ARM/PPC int64 encodings) | Low | Per-backend CI arch runs (QEMU or native) |

## 9. Deliverables

- `luajit-5.4` git repo (base: 2.1 tree, phases as labeled commits)
- `tests/`: adapted PUC suite + `tests/d54/` + fuzzers (source-fuzz,
  dump-reload-fuzz, GC-fuzz) + `harness.sh` + CI config
- `docs/54port.md`: semantic-delta checklist with test references
  (every §4 box linked to its test)
- Release: `LuaJIT-5.4.0.tar.gz`, release notes, perf report

## 10. Open questions (resolve in Phase 0)

1. Exact opcode encoding for 64-bit int constants in a compact 5.4
   header (EXTRAARG pairing across register-file limits) — validate
   against PUC `luac -l` on x64.
2. Does the JIT need full 64-bit constant folding, or may it deopt
   exotic int constants? (Proposal: full support; deopt is a correctness
   backstop, not a design.)
3. 5.4 `%g` shortest-representation algorithm: adopt PUC's
   `str2c`/`lua_number2str` implementation verbatim (proposal: yes,
   copy from reference).
4. How much of 2.1's `lj_strfmt` parse path is reusable for `tonumber`
   5.4 (hex/float/underscore rules) — expect a rewrite of the number
   parser per 5.4 grammar.
5. Coroutines: 5.4 `coroutine.close` + `xpcoroutine` error semantics —
   confirm against PUC test suite (coroutine test file).

---
*End of mission. Phases are sequential; each milestone is a shippable
interpreter-correct or JIT-correct intermediate state that is
independently demonstrable on the harness.*
