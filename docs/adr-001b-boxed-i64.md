# ADR-001b — boxed, interned int64 (spike; decision belongs to Markus)

Status: **spike step 1 landed** (C-side box + intern + C display paths, verified by
a C test); Lua-visible use is blocked by step 2/3. ADR-001 (16-byte `TValue`)
demoted to documented fallback. Second opinion: the former internal coordinator answer (plus Markus
addenda 1 and 2).

`arm64-build` and `x64-build`, named below for the runs, are private wrappers
that run a command on a remote arm64 / x86_64 test host.

## Measured findings (this session)

1. **A new GC tag is unsafe on GC64** (the analysis below assumed one; measurement
   refuted it). Adding `LJ_TI64 = ~13` and moving `LJ_TNUMX` to `~14` broke
   agreement between the C side and the interpreter: `math.type(3)` answered
   *float* in a freshly built VM, and the harness hung. Cause: the GC64 tag
   encoding is 17 bits wide and the VM's form (`(LJ_TISNUM>>1)&0xffff` in
   `vm_*.dasc` `init_constants`) drops the tag's bit 0, while C's `setitype()`
   keeps it. `~13` has bit 0 = 0 (today, works); `~14` and `~13`-as-I64 have
   bit 0 = 1 (diverge). So the box must not use a new tag.
2. **Chosen representation: a private `udtype`.** Box = an interned `GCudata`
   with `udtype = UDTYPE_I64BOX` holding one `int64_t`; `tvisi64()` is
   `tvistudata && udtype == UDTYPE_I64BOX`. No new GC plumbing.
3. **A userdata's `env` must never be NULL**: `gc_mark()` marks it
   unconditionally; passing NULL crashed during collect. The box uses globals.
4. **Interning** lives in a registry-anchored table keyed by the 8 raw bytes of
   the value. Pointer equality == value equality (raw compare, table keys and
   same-type GC-pointer compares stay correct without new code).
5. **Lua-visible use crashes the interpreter's fast formatting path**: pushing
   a box as `math.maxinteger` segfaults in the VM on `print(math.maxinteger)`
   (C `lj_strfmt_obj`/`%d` handle it; the print fast function does not). That is
   the evidence Markus asked for: boxing does not stay out of the fast paths —
   step 2 must teach print/format, arithmetic dispatch and compares the box.

## Decision to be made (Markus)

Two ways to give Lua 5.4 exact 64-bit integers on a LuaJIT base:

| | A. 16-byte `TValue` (old ADR-001a) | B. boxed, interned int64 (this ADR) |
|---|---|---|
| representation | every value 16 bytes; int64 in the high word | int32 inline (dual-number) stays; values outside int32 are an interned GC object holding int64 |
| cost | every stack slot, table value, GC object grows; cache footprint doubles for all programs | one allocation + one hash lookup only where a value leaves int32; always correct, slower only on that code until the JIT sinks the boxes |
| risk | slot size = pointer size = frame-link size: GC64 two-slot frames (`LJ_FR2`), JIT SLOAD/stack-restore offsets, snapshots/trace exits, table array parts, hash `Node`, upvalues, FFI conversions, seven interpreters — each site needs a "slot or pointer?" decision, and the harness only catches what it exercises | new GC type + intern table + GC/lj_obj/IR plumbing; VM arithmetic gains an overflow exit per op (not per slot) |
| buildability | step 1 breaks every VM at once; nothing runs until step 3 lands per backend | tree stays buildable and green after each step |
| verdict | fallback, only if B forces changes into every arithmetic fast path | **preferred** |

the coordinator's precedent check: there is no 16-byte-value LuaJIT branch or patch anywhere in the fleet, and
deferring int64 entirely does not meet MISSION §2 goal 1. Staging the int64 work is fine and is what
`tests/known-bad.tsv` already records.

## What the spike must show (arm64 only, via `arm64-build`)

Succeed = green without touching slot code, on these three tests:

- `tests/d54/numeric_01_types.lua` — `math.maxinteger` / `math.mininteger`, wrap
- `tests/d54/numeric_03_idiv.lua` — `//` parses and runs
- `tests/d54/bits_01_ops.lua` — 64-bit shifts (`1 << 64` == 0, `-1 >> 1` == maxinteger)

Then write it up here and keep 16 bytes as the documented fallback. If it instead forces edits into
every arithmetic fast path, go back to A with the measured diff as evidence.

## Design (as spiked)

- **Inline fast path unchanged.** int32 stays the value in the slot (dual-number). arm64 is
  `LJ_ARCH_NUMMODE_DUAL` natively; x64/x86 are `SINGLE_DUAL` and now build with
  `-DLUAJIT_NUMMODE=2` (`src/Makefile`), so both machines use the same number model — checked by
  `tests/ci-box.sh` printing `math.type(3)`.
- **Box:** an immutable GC object holding one `int64_t`, interned in a hash so that pointer equality
  means value equality. Raw equality, table keys, and the existing same-type GC-pointer compare then
  keep working without new fast-path compare code.
- **Interpreter:** only the overflow exits change. Today int32 arithmetic overflows into a double;
  instead it goes to a C helper that returns the box. A handful of exits per backend (ADD/SUB/MUL/UNM,
  bitwise, IDIV, MOD), not every slot access.
- **C semantics:** `math.type`, `tostring`, `string.format('%d')`, comparisons, and 5.4 table-key
  normalisation (an integral float key becomes an integer key).
- **JIT:** step one is NYI — the recorder aborts on a boxed tag and the interpreter runs the code,
  which stays correct. Later `IRT_I64` + reuse of the existing 64-bit-cdata sinking
  (`lj_opt_sink.c`, `lj_crecord.c`) for performance.

## Tag space — refuted by measurement

The pre-spike analysis below is kept for the record, but finding 1 above refutes
it: a new GC tag cannot be represented consistently on GC64 at all, so the box
uses a private udtype instead. The analysis still explains why the 16-byte
fallback is expensive (`tvisgcv` contiguity, `itype2irt` mapping, NUMX-derived
arrays).

## Tag space (original analysis)

Current tags (`lj_obj.h`): `LJ_TNIL ~0 … LJ_TSTR ~4, UPVAL ~5, THREAD ~6, PROTO ~7, FUNC ~8,
TRACE ~9, CDATA ~10, TAB ~11, UDATA ~12, NUMX ~13`.

Constraints found by reading the tree:

1. `tvisgcv()` is a **contiguous range**: `(itype - LJ_TISGCV) > (LJ_TNUMX - LJ_TISGCV)` with
   `LJ_TISGCV = LJ_TSTR+1`. A new GC tag must therefore live *inside* that run, i.e. before `NUMX`,
   and `LJ_TNUMX` moves from `~13` to `~14`.
2. `itype2irt()` returns `(IRType)~itype(tv)` for GC tags, and `IRTDEF` indices mirror the tag order:
   index 13 is `IRT_FLOAT`. A tag at `~13` would therefore be reported as a float to the recorder.
   So `itype2irt()` needs an explicit case for the new tag, and `IRTDEF`/`IRTENUM` gain a matching type
   (`IRTDEF` documents "room for 8 more types", so appending is possible without renumbering).
3. `lj_obj_itypename[]` is sized `~LJ_TNUMX+1`, `GCROOT_BASEMT_NUM = GCROOT_BASEMT + ~LJ_TNUMX`, and
   `lj_obj_typename`/`itypemap` map through `~LJ_TNUMX`; all shift by one when NUMX moves.
4. Marking/barriers: the gc-type enumeration (`lj_gc.h`/`lj_gc.c`), the object-size table, and
   `lj_tab`'s key specialisation must learn the new type; interning mirrors `lj_str.c` (hash, intern
   table, fixstring-like immutability).

Net: one new tag `LJ_TI64 = ~13`, `LJ_TNUMX = ~14`, explicit `itype2irt` case, new `IRT` entry.

## Migration order (green after every step)

1. GC type + intern table + accessors; C semantics (`tostring`, `tonumber`, `math.type`, comparisons,
   table-key normalisation, `'%d'`). Only C helpers reach them, so no test changes yet.
2. Lexer/parser: integer constants beyond int32 become boxed constants (KGC); `//` parses with a new
   `BC_IDIV` and runs through the C helper first; dump format with EXTRAARG.
3. VM per backend, arm64 first then x64: the arithmetic overflow exits, bitwise ops, `BC_IDIV`,
   `MOD` go to the C helper; arithmetic dispatch accepts the boxed tag as a number (a `vmeta`
   fallback is acceptable initially).
4. JIT recorder: NYI on the boxed tag (correctness preserved). 5. Later: `IRT_I64` lowering + sinking.

## Verification

Each step: `arm64-build -t 1200 sh tests/ci-box.sh`. Step 1 verified: modes A+B
42 PASS / 0 FAIL, opt levels 0–3 124 PASS, mode R 31 PASS, C API 34/34 plus the
new box test 7/7, short GC fuzz 160/160.

## Step 6 (documented refinement, NOT part of the spike): 47-bit inline integers

Markus's addendum 2 points at CogVM/Spur: SmallIntegers up to 61 bits live inside
the tagged word and only larger values become heap objects; make the unboxed
range as wide as the tag scheme allows.

For LuaJIT GC64 the `TValue` has a 47-bit payload under a 17-bit itag, so
integers could live inline up to signed 47 bits; only true 64-bit values
(hashes, 64-bit masks, PRNG state) would box. 47 bits cover ms timestamps
(~41 bits), file offsets and almost every counter.

Cost: the overflow check moves from the native 32-bit overflow flag to a 64-bit
operation plus a 47-bit range check (sign-extend and compare), so every VM fast
path and the JIT's integer guards change. Non-GC64 targets stay int32.

`tests/bench/b2b_ms64.lua` measures exactly this window. The spike itself stays
int32-inline; 47-bit is decided after the numbers.

## Step 2-3 status (2026-11-15, later session)

aarch64 is complete and green: `//` with its own BC_IDIV, MM_idiv, 5.4 int64
wrap arithmetic, floor `//`/`%`, 64-bit shifts and bitwise ops through the C
helper, floats with exact integer representation accepted, 5.4 error wording.
tests/d54/numeric_03_idiv.lua and bits_01_ops.lua PASS in modes A, B and R
(mode A identical to PUC 5.4.7). Gate: A+B 47 PASS / 0 FAIL / 17 XFAIL,
opt 0-3 128 PASS, R 32 PASS, C API 34/34 + i64 14/14.

x64 (the x64 build box) is NOT complete. Shifts work, but a runtime BC_IDIV (`local a=7
local b=2; a//b`) yields a value whose printed type is "table": the destination
slot receives the box with a GC pointer but a tag that decodes as ~11, i.e. the
udata tag is not encoded consistently on x64 -- or the destination slot pointer
is off by one. Reproductions:
  x64: local a=7 local b=2 print(a//b)          -> "table: 0x..."
  x64: local a=math.mininteger local b=-1 print(a//b==math.mininteger) -> false
Note: the *constant-folded* `7//2` path works on both boxes (PASS), so this is
specifically the runtime BC_IDIV store on x64. Also already measured: GC64 tag
encoding preserves only tags with bit 0 = 0, so LJ_TNUMX must stay odd (~13) --
~14 broke VM/C agreement and was reverted.

## Benchmark gate result (arm64-build, median of 3, 2026-11-15)

Boxed interned int64, steps 2-3 + literal constants, recorder NYI for boxes.
"alloc" is the collectgarbage("count") delta of our arms.

| bench | ours JIT on | ours -joff | stock 2.1 FFI uint64 | PUC 5.4.7 |
|---|---|---|---|---|
| B1 FNV-1a-64, 10 MiB | **16080 ms** | 17851 ms | **15.1 ms** | 286.5 ms |
| B2 table of 1e6 64-bit values | 3450 ms, **899 MB** alloc | 3590 ms, 899 MB | 690.7 ms, 31.6 MB | 522.8 ms, 16.4 MB |
| B2b table of 1e6 ~2^41 values | 773.8 ms, 253 MB alloc | 753.9 ms | 138.7 ms, 8.2 MB (float) | 171.6 ms, 16.4 MB |
| B3 int32 control | 37.9 ms | 5439 ms | 42.3 ms | 279.9 ms |

Against Markus's gates:

- **B1 fails hard**: 16080 ms is ~1060x the FFI yardstick (15.1 ms), not within
  1.5x. The recorder aborts on boxes (step 4), so not a single 64-bit operation
  is compiled; every op allocates and interns. Step 5 (IRT_I64 + sinking) is
  the only fix for compute -- and it is untested here.
- **B2 fails both halves**: it allocates per element (899 MB, ~900 bytes per
  value: udata + interned 8-byte key string + registry nodes) and is 6.6x
  slower than PUC. Interning by string key is the dominant memory cost.
- **B2b fails**: 773.8 ms / 253 MB vs PUC 171.6 ms / 16.4 MB. This is exactly
  the window Markus's addendum 2 targets: with 47-bit inline integers these
  values would not box at all.
- **B3 does not regress**: 37.9 ms vs stock 42.3 ms (JIT int32 path untouched).
  The interpreter side degraded (5439 ms) because int32 overflow now boxes --
  visible, and consistent with 5.4 semantics.

Interpretation for the ADR decision: boxed int64 is *correct* and green on both
boxes, but as implemented it cannot meet B1/B2 without (a) step 5 lowering and
(b) a cheaper box representation (dedicated i64 intern hash, not string keys),
and B2-class memory needs 47-bit inline integers (step 6). 16-byte TValue would
fix B2 memory (~2x slots) but not B1 compute without the same IRT_I64 work.

## Step 1 done: dedicated int64 intern hash (2026-11-15)

Boxes are now interned in an open-addressing hash keyed by the int64 value
(GCRef anchors in global_State, NULL = empty, 1 = tombstone, grow at 75%).
The table is not a GC root, so entries are weak by construction; the sweep
removes a dead box's entry before freeing it (lj_gc.c) and the table is freed
on state close (lj_state.c / lj_i64_freetab). Verified: identity across
collection, table-key use, 100 interned values survive two full GCs. Gates on
both boxes green: A+B 47 PASS / 0 FAIL / 17 XFAIL, opt 0-3 128 PASS, R 32 PASS,
C API 34/34 + i64 14/14.

Benchmark after step 1 (arm64-build, median of 3):

| bench | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 FNV-1a-64 | 8510 ms | 8461 ms | 8.9 ms | 276.8 ms |
| B2 1e6 64-bit values | 2211 ms, 522 MB | 2220 ms, 522 MB | 624 ms, 31.6 MB | 532 ms, 16.4 MB |
| B2b 1e6 ~2^41 | 400 ms, 150 MB | 392 ms, 150 MB | 137 ms, 8.2 MB (float) | 171 ms, 16.4 MB |
| B3 int32 control | 37.9 ms | 3663 ms | 46.4 ms | 277.9 ms |

Effect: B1 16080 -> 8510 ms (2x), B2 899 -> 522 MB (1.7x), b2b 253 -> 150 MB
(1.7x). The raw string-key overhead is gone, but B2 is still far from the
16-32 B/value target: a box is a GCudata (~56 B) plus hash anchors and GC
turnover, so "allocates per element" still holds. B1 still ~950x the yardstick
because the recorder is NYI on boxes.

Interpretation: the remaining memory cost is inherent to one-object-per-value,
i.e. the 47-bit inline-integer step (step 6 / order step 2) is what actually
reaches the B2/B2b targets; step 5 then fixes B1 compute.

## Step 6 moved forward: 47-bit inline integers on GC64 — DESIGN (order step 2)

Owner decision (Markus): the int fast path and its overflow checks move from
int32 to **signed 47-bit on GC64**; non-GC64 targets stay int32. Cog/Spur
precedent: SmallIntegers inline as wide as the tag word allows, LargeInteger
objects only beyond.

### Encoding (derived from the actual GC64 scheme, measured)

`TValue` on GC64: `it64 = i | (it << 32)`, `itype(o) = (uint32_t)(it64 >> 47)`,
tag read is sign-extended: `itype == 0xFFFFFF00 | (tag & 0x1FFFF)` when the
NaN-box high bits are all ones. Payload bits 0..46 are free; bits 47..63 hold
the 17-bit tag. Critically, the VM's TISNUM constant is derived as
`((LJ_TISNUM>>1)&0xffff)<<48`, which is consistent with the C encoding only for
tags whose value has bit 0 = 0 — consequently **LJ_TNUMX must stay odd** (it is
~13 today; ~14 broke VM/C agreement and hung the harness; a new GC tag would
force NUMX even unless a second spare tag is added).

Signed 47-bit inline integer encoding (`LJ_I47`):

    o->i  = (uint32_t)v;                         /* payload bits 0..31 */
    o->it = ((uint32_t)(LJ_TISNUM & 0x1FFFF) << 15) |
            ((uint32_t)(((uint64_t)v >> 32) & 0x7FFF));

Read back (`intV47`):

    uint64_t u = o->u64 & 0x7FFFFFFFFFFF;         /* bits 0..46 */
    int64_t  v = (int64_t)(u << 17) >> 17;        /* sign-extend bit 46 */

Range: `LJ_I47_MIN = -((int64_t)1 << 46)`, `LJ_I47_MAX = (1 << 46) - 1`
(±7.04e13; ms timestamps at ~1.7e12 fit; file offsets fit; 64-bit hashes,
64-bit masks and PRNG state do not).

Invariant: a value is inline iff it fits signed 47 bits; everything wider is a
boxed interned int64 (unchanged representation). `setintV(int32)` keeps the
current encoding path (payload wholly in the low word) — the widened form must
be distinguishable from it, which it is: bits 32..46 nonzero (or a sign
extension differing from int32) means widened.

### Range test for the fast paths

Every asm/C site that reads an inline integer and truncates to 32 bits must
first prove "fits int32". Cheap test on the encoded word: the high payload
bits are the sign extension of bit 31, i.e.
`(it & 0x7FFF) == 0x7fff` for negative int32 values and `== 0` for positive.
So per operand: `ands`/`cmp` of `(it & 0x7fff)` against 0 or 0x7fff — two
instructions; branch to the C helper when widened.

### Migration order (green after each sub-step)

1. C primitives (this sub-step), unused at first: `LJ_I47_MIN/MAX`,
   `setint64V` widened encoding, `intV47`, `i47_fits`, `tvisi47` predicate;
   keep `intV` as the int32 accessor and add `i64V`-like extraction
   (`lj_i64_getint` already returns exact int64 for int32 AND box — extend it
   to the widened inline form). No call sites change: tree stays green.
2. C call-site audit: every `intV(o)`/`setintV` use must either be provably
   int32 (constants, indices, lengths) or move to the exact accessor. Grep
   list: `intV(` in lj_*.c, lauxlib/lua_api/parse/strfmt/bcwrite/serialize.
   Gate: full harness both boxes.
3. VM fast paths, arm64 first then x64: checkint gains the range test; on a
   widened operand or an overflow, the arith cases route to `lj_i64_arith`
   (already written) which now stores inline when the result fits 47 bits.
   Same for bitwise (the helper already computes int64; only its store rule
   changes) and MOD/IDIV.
4. JIT int guards: IRT_INT currently means int32. Decision needed (see below):
   either (a) treat IRT_INT as "int32-proven" and keep recorder NYI when a
   value may be widened, or (b) widen IRT_INT to 47-bit with new guard forms.
   Proposed: (a) first — recorder checks the widened-range bit and aborts,
   correctness kept, B3 unaffected because int32 range values are proven.
5. Bench: B2b must show no boxes; B3 no regression; B2 memory becomes ~16-32
   B/value ONLY for values ≤47 bits, larger values still box.

### Design decision to put to Markus/Claude (if it becomes blocking)

The JIT's integer type: LuaJIT's IR has `IRT_INT` (32-bit) and IRT_I64. With
47-bit inline values, a trace that guards "is inline integer" can still read a
value beyond 32 bits. Option (a) (IRT_INT = proven int32, recorder NYI when a
widened value appears) is the low-risk staging; option (b) widens IRT_INT and
every arithmetic encoding/guard. Plan: implement (a) inside step 6, and only
revisit (b) if the B1/B2 numbers after step 3 demand it.

### What a fresh context must know

- Repo at the project root, branch main; bare origin outside the working tree.
  Local builds are REFUSED on the build host (external guard);
  verify only via `arm64-build -t 1200 sh tests/ci-box.sh` (on the arm64 build box) and
  `x64-build -t 1200 sh tests/ci-box.sh` (on the x64 build box). Both do a fresh copy +
  clean build; always include `make clean` in ad-hoc box jobs — a copied
  `src/luajit` from the build host is a foreign-arch stale binary otherwise.
- Benchmark gate: `arm64-build -t 1800 sh tests/bench/run.sh` (four arms, median of
  3; prints B1, B2, B2b, B3; "unsupported"/"FAILED" lines mean the model lacks
  something). Current numbers are in the table above.
- After each step: gate both boxes, commit+push, `send claude` the benchmark
  table (the coordinator relays to Markus), continue.

### Sub-step 1 landed (green, inert): primitives + first consumers

Committed: `LJ_I47_MIN/MAX`, `i47_fits`, `setint47V` (widened encoding),
`intV47`, `tvisi47w` in lj_obj.h; `lj_i64_getint` reads the widened form;
formatting and numeric coercion (`lj_strfmt` wstrnum/%d/%x/%q/number,
`lj_meta` number coercion + concat) use the exact value for widened ints.
Nothing stores a widened integer yet, so the tree stays green (both boxes
compile; harness unchanged).

### AUDIT LIST for sub-step 2b (widened values become reachable)

Every site where a widened inline integer can arrive and `intV()` would
truncate to 32 bits. Measured in this tree (~100 `intV(` sites):
- `lj_tab.c:408,543,577` (int key lookup/set), `lj_tab_getint/lj_tab_setint`
  take int32: widened keys need a 64-bit hash-part path.
- `lj_strfmt.c` done; `lj_meta.c:315,320,323,338` legacy 32-bit bitop path
  (dead after our rewrite except non-FFI builds), `lj_meta.c:584-597` (for-loop
  preparation: intV on start/stop/step).
- `lj_bcwrite.c`/`lj_bcread.c` int constants (KFOLD/KNUM narrow path).
- `lj_api.c` (lua_tointegerx/lua_pushinteger/lua_objlen), `lib_base.c` (optint,
  tonumber base, select, rawlen), `lib_string.c` (indices/lengths are
  int32-bounded by API), `lib_table.c`, `lib_math.c`, `lib_bit.c` (tobit),
  `lib_ffi.c`, `lj_carith.c`, `lj_cconv.c`, `lj_debug.c` (line numbers),
  `lj_serialize.c`, `lj_asm.c`, `lj_buf.c`.
- VM fast paths: `checkint` (tag test) must gain the range test
  (`(it & 0x7fff)` == 0 or 0x7fff); arithmetic/bitwise/MOD/IDIV route widened
  operands to `lj_i64_arith`; `lj_i64_store` should store widened inline when
  the result fits 47 bits (setint47V) instead of int32-or-box.
- Comparison/equality: `lj_obj_equal` (pointer/interned path unchanged),
  `lj_meta_comp` (box-aware already), VM `BC_ISEQ*` int-int compare must use
  exact values; `lj_meta_less`? not present.
- JIT recorder: `IRT_INT` remains "proven int32"; the recorder must abort
  (NYI/BADTYPE) when a `tvisi47w` value appears in a slot or constify path.
Rule for the audit: integer values that are *indices/lengths/lines* stay
int32-bounded by the language or the API; anything that can be a user value
uses the exact reader.

## Step 3 time-box result and resumption plan (2026-11-15)

Time-boxed attempt (commit `b99fe41d`, reverted to keep the step-2 gates):

1. What works: the **raw IRT_I64 slot model**. With `snap_restoreval` handling
   IRT_I64 (spill and register branches, encoding via `lj_i64_toTValue`), a loop
   that is widened from entry runs in mcode: 1,000,000 iterations in ~0.38 ms,
   values and exit encoding exact (e.g. `local s=1<<40; for i=1,300000 do
   s=s+p end` ~0.13 ms in mcode).
2. Where it stops: the **int32 -> I64 type transition inside a root trace**.
   Loops that start at an int32 value and overflow into widened values (b1's
   `h`, b3's `st`) retry the root trace 55-165 times with LJ_TRERR_NYICOAL
   (register coalescing up on the mixed-type PHI) and fall back to the
   interpreter; b3 then takes 4325 ms instead of the 46 ms int32 path. That
   model also removed the b3 JIT-vs-joff checksum divergence (both now
   == PUC's 1196193376), but at that cost.
3. Resumption rule: **never promote a slot's type inside a trace**. Do it the
   way LuaJIT already handles int->num:
   - the int32 trace keeps ADDOV/SUBOV/MULOV guards;
   - a guard overflow exits to the interpreter, which computes the widened
     (5.4) value;
   - the next recording (side trace from that exit, or a fresh root once the
     loop entry slot is already widened) specialises the slot as I64 from the
     start, so each trace is type-stable;
   - a loop whose PHI would need two types must abort and re-record with the
     new entry type (LJ_TRERR_TYPEINS-style retry), never emit a mixed-type PHI.
4. To build:
   - recorder rule "slot widened at trace entry -> IRSLOAD_I47 / boxed udata
     payload load as I64" (only at entry, not mid-trace);
   - abort-and-retry when a loop PHI's entry type changes (rec_loop /
     LJ_TRERR_TYPEINS);
   - keep the `snap_restoreval` IRT_I64 branch and `lj_i64_toTValue` from the
     time-box (they are correct and are now in the tree, inert until a I64 TRef
     exists).
5. Gates for the resumed step: b1 <= 1.5x stock FFI; b3 back to ~46 ms with the
   JIT and -joff checksums both 1196193376; full suites green on arm64 and x64.

## Step 3 implementation (2026-11-16, branch `step3-i64`)

Shipped on arm64 and x64. The IR_BOX allocation model of the time-box is not
used; a 5.4 integer travels through a trace as a raw `IRT_I64` register value.

### Representation rule (the design decision)

In a trace an `IRT_INT` ref always stands for an int32 inline TValue, and an
`IRT_I64` ref for a 5.4 integer that does not fit int32 (widened 47-bit inline
or interned box). A result that fits int32 is narrowed back to `IRT_INT` under
a guard right where it is produced (`CONV INT<-I64 CHECK`, new in both
backends: `cmp x, w, sxtw` / `movsxd + cmp`). So a slot's IR type follows the
interpreter's representation, a type never changes inside a trace, and an exit
can re-encode a value from its IR type alone (`lj_i64_toTValue`, kept from the
time-box). This mirrors the stock recorder's int-vs-num decision by the actual
result: `lj_opt_narrow_arith` emits `ADDOV/SUBOV/MULOV` when the exact int32
result fits and the 64-bit operation on sign-extended operands when it does
not. For the rule to hold the *interpreter* must keep boxes canonical: a box
never holds an int32-range value. Three places violated that and were fixed
(the parser negated boxed literals in place -- through the FFI cdata fold --
corrupting the intern table; the lexer boxed hex literals that wrap into int32;
`lj_i64_push` boxed unconditionally).

### Pieces

- **Slots.** `SLOAD` with the new `IRSLOAD_I64` mode accepts both
  representations with one guard (`itype == TISNUM && payload bits 32..46 != 0`,
  or `itype == TUDATA && udtype == UDTYPE_I64BOX`) and decodes to a 64-bit
  register (`asm_i64decode`, arm64 and x64). A slot whose value alternates
  between the two forms therefore does not flap between traces. x64 must not
  fuse such an SLOAD as a memory operand (`asm_fuseload`): the raw word is not
  the value.
- **Constants.** `BC_KI64`, widened and boxed constants become `KINT64`;
  `snap_restoreval` encodes a `KINT64` slot canonically instead of the cdata
  `lj_ir_kvalue` would make.
- **Operations.** `+ - *` wrap on `IRT_I64` (existing FFI backend code);
  `& | ~ ~x`; shifts are always 64-bit (5.4: `1 << 40 == 2^40`, counts >= 64
  give 0, negative counts reverse) -- constant counts become native shifts,
  variable counts call `lj_i64_shl/shr`; `%` calls `lj_i64_mod` under a
  divisor != 0 guard; unary minus wraps (`-mininteger == mininteger`,
  `-(-2^31) == 2^31`, `-0 == 0`); `/`, `^` and any float operand convert to
  float. Ordered compares and equality use 64-bit IR compares; int64 against
  float is left to the interpreter (exact compare).
- **Loops.** `lj_opt_loop`: an int32 entry type with an int64 back edge gets
  the checked narrowing on the back edge, an int64 entry with an int32 back
  edge gets a sign extension -- the same shape as the int/num fix. The side
  trace from the narrowing guard records the loop with the wide type and, when
  it reaches its own start, forms its own loop (`rec_loop_jit`), so a loop
  whose accumulator crosses 2^31 ends up fully compiled with int64.
- **Trace tails.** Machine code cannot produce the canonical TValue of an int64
  (int32 / widened / box, the latter allocates). `lj_record_stop` therefore
  stores int64 slots through `lj_i64_tvstore` (a CALLS with `BASE + 8*slot`)
  before any non-loop link or return and drops them from the final snapshot.
  Looping traces keep them in registers.
- **Not recorded (NYI aborts, interpreter stays exact):** int64 table values
  and keys, int64 upvalues, fast functions with int64 arguments, int64 vs float
  compares, `//`, string coercion to int64. Each needs the unified load guard
  (`asm_ahuvload`) or the store helper with a GC barrier; none is on the
  benchmark paths.

### Interpreter fixes found by the new test (tests/d54/i64_02_jit.lua)

- BC_UNM on both VMs returned floats for `-0` and `-(-2^31)` and negated the
  low word of a widened operand; `lj_meta_arith` did not route `MM_unm` to the
  int64 helper.
- BC_ISEQV/ISEQN compared low words (x64: `2^40+5 == 5` was true) or raw
  words with a tag test (arm64: `(1<<40) == 1099511627776` was false). Whole
  words are compared on the int path (canonical encodings), and every case with
  a widened value or a userdata goes to `lj_meta_equal_any` (new VM label
  `vmeta_equal_i64` on both backends).
- `lj_i64_arith`'s mixed int64/float path read the low word of a widened
  operand (`(1<<40) + 0.5` gave `0.5`).

### Gates (commit deadff71, 2026-11-16)

`tests/ci-box.sh` on both boxes: modes A+B 55 PASS / 0 FAIL / 16 XFAIL / 1
XPASS (meta_02_compare_len, now removed from known-bad: exact int/float
equality), mode B at opt 0-3 144 PASS, mode R 36 PASS, C API 34 + i64 14/14,
fuzz 160/160. Pre-existing and unchanged: `-jv`/`-jdump` of a script with
boxed literals segfaults in jit.util (also at the base commit 1e883ab8).

Benchmark gate `tests/bench/run.sh`, median of 3, same box, same moment:

| bench (arm64, the arm64 build box) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 FNV-1a-64, 10 MiB | **16.4 ms** (1.08x FFI) | 6870.6 ms | 15.2 ms | 292.1 ms |
| B2 1e6 64-bit values | 2279.7 ms, 522 MB | 2264.2 ms | 698.7 ms | 565.3 ms |
| B2b 1e6 ~2^41 values | 270.0 ms, 79 MB | 285.2 ms | 147.6 ms (float) | 162.9 ms |
| B3 int32 control (fnv / table) | **20.9 / 209.3 ms** | 4323.7 / 684.9 ms | 37.9 / 200.8 ms | 308.9 / 253.5 ms |

| bench (x64, the x64 build box NUC) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 | **30.2 ms** (1.03x FFI) | 21468 ms | 29.2 ms | 1332 ms |
| B2 | 7327.7 ms | 7600.5 ms | 2596.0 ms | 2159.7 ms |
| B2b | 1135.4 ms | 1134.2 ms | 613.0 ms | 730.0 ms |
| B3 | **47.6 / 945.3 ms** | 10722 / 1838.7 ms | 96.9 / 860.6 ms | 1296.7 / 989.3 ms |

Checksums: B1 343592796160 and B3 1196193376 on both arches, JIT == -joff ==
PUC. Against the step-3 gates: B1 within 1.5x of the FFI yardstick on both
arches; B3 faster than stock; B2/B2b unchanged (their loops store int64 values
into tables, which is still a NYI abort -- the next step: `ALOAD/HLOAD` with
the unified int64 guard and a `lj_i64_tvstore` + TBAR store path).

## Step 3, part 2 (2026-11-16, branch `i64-part2`): int64 through tables, upvalues, varargs

Same representation rule as step 3 (IRT_INT ref == int32 inline, IRT_I64 ref
== widened or boxed), extended from stack slots to memory:

- **Loads.** `ALOAD/HLOAD/ULOAD/VLOAD` of a widened or boxed value are typed
  `IRT_I64` and decoded by the unified guard (`asm_i64decode`: widened payload
  or `UDTYPE_I64BOX` payload, exit otherwise) in both backends. The slot type
  comes from the value seen at record time (`itype2irt_i64`); a slot that
  alternates int32/widened/boxed just exits and re-records like any other
  polymorphic slot. `pairs()`/`next()` value types and vararg slots follow.
- **Stores.** An int64 ref is stored with an ordinary `ASTORE/HSTORE/USTORE`
  whose backend path calls `lj_i64_tvstore(L, slot, v)` (canonical
  int32/widened/box encoding, interning included) with the usual `TBAR`/`OBAR`,
  so FWD/DSE/sink see a normal store. Two consequences that cost a morning:
  - `gcstep_barrier()` in lj_opt_fold.c must treat an int64 store as an
    allocation (it may intern a box), otherwise the loop copy of the barrier is
    CSEd across the GC step at `LOOP`: a propagate step blackens the table and
    the loop then stores white boxes without a barrier (boxes freed under a
    live table; the B2 checksum varied per run).
  - x64 `asm_fuseload` must not fuse an `IRT_I64` load as a memory operand
    (same class as the `IRSLOAD_I64` fuse in step 3): the consumer would see
    the raw TValue word instead of the decoded int64.
- **Compares.** int64 vs float ordered compares and equality go through
  `lj_i64_cmpnum` (exact, long double; NaN = unordered) plus an int compare on
  its result. The x64 interpreter's `ISLT` family compared only the low 32 bits
  of two widened ints; it now routes widened operands to `vmeta_comp`.
- **`//`** (BC_IDIV) is recorded: integer floor division via `lj_i64_idiv`
  under a divisor guard, float operands via `floor(a/b)`.
- **Fast functions** that only copy/compare/type-dispatch (`type`, `select`,
  `assert`, `pcall`, `xpcall`, `rawequal`) accept int64 arguments; all others
  still abort recording on an int64 argument.
- **Still NYI: int64 table keys** (`t[1<<40]`): the recorder aborts; the
  interpreter path is exact.

Test: `tests/d54/i64_03_jit_tables.lua` (array/hash parts, alternating slot
representations, upvalues, varargs, pairs, int64 vs float compares incl. NaN,
`//`, fast functions with int64 args) in mode A (vs PUC) and B (JIT vs
interpreter).

### Gates (commit 8742442c, 2026-11-16)

`tests/ci-box.sh` on both boxes, identical: modes A+B 75 PASS / 0 FAIL / 13
XFAIL / 0 XPASS, mode B at opt 0-3 172 PASS / 0 FAIL / 4 XFAIL (math_os_01 B
from main), mode R 44 PASS, C API 34 + i64 14/14, fuzz 160/160.

Benchmark gate `tests/bench/run.sh`, median of 3, same box, same moment
(the arm64 build box shares its CPU with model serving; its -joff arm was ~2x slower than
in the step-3 run, the JIT arms are what the gate is about):

| bench (arm64, the arm64 build box) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 FNV-1a-64, 10 MiB | **14.9 ms** (0.98x FFI) | 13347.7 ms | 15.2 ms | 311.6 ms |
| B2 1e6 64-bit values | **1358.6 ms, 79 MB** (was 2279.7 ms, 522 MB) | 4548.8 ms, 522 MB | 719.0 ms, 31.6 MB | 598.0 ms, 16.4 MB |
| B2b 1e6 ~2^41 values | **148.1 ms, 8.2 MB** (was 270.0 ms, 79 MB) | 394.1 ms, 79 MB | 139.7 ms (float) | 176.8 ms |
| B3 int32 control (fnv / table) | **22.2 / 226.4 ms** | 8304.0 / 1118.6 ms | 38.0 / 203.2 ms | 320.9 / 284.4 ms |

| bench (x64, the x64 build box NUC) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 | **30.4 ms** (1.04x FFI) | 21658.2 ms | 29.2 ms | 1331.3 ms |
| B2 | **3405.9 ms, 79 MB** (was 7327.7 ms, 522 MB; 3095.3 in the run before) | 7522.6 ms, 522 MB | 2589.7 ms, 31.6 MB | 2151.5 ms, 16.4 MB |
| B2b | **675.4 ms, 8.2 MB** (was 1135.4 ms, 79 MB) | 1147.7 ms, 79 MB | 612.6 ms (float) | 729.7 ms |
| B3 | **47.7 / 967.3 ms** | 10710.3 / 1875.4 ms | 96.9 / 856.9 ms | 1305.6 / 989.8 ms |

Checksums on both arches, JIT == -joff == PUC: B1 343592796160, B2 4047905256
(the step-3 report had no stable B2 checksum under the JIT; see the barrier bug
above), B2b 299440, B3 1196193376. Against the part-2 target "B2/B2b toward
the FFI/PUC arms": B2b is at the FFI arm (arm64 1.06x, x64 1.09x) and below
PUC on both; B2 went from 3.2x/2.8x FFI to 1.9x/1.3x FFI (arm64/x64) and from
522 MB to 79 MB -- the remaining gap is the sort with a Lua comparator (boxed
compares through a call frame) plus one intern lookup per store; a widened
value stores without any allocation now.

## Step 3, part 3 (2026-11-16, branch `i64-keys`): int64 table keys

Before: a widened key was turned into a float key, a boxed key hashed by its
box pointer, so `t[2^60]` and `t[1<<60]` were two keys, `next()` returned
floats for sparse integer keys (`t[100000]` came back as `100000.0`, a
divergence inherited from stock DUALNUM LuaJIT, which keeps integral hash
keys as floats), and the recorder aborted on int64 keys.

Design: **an integral key lives in the hash part in its canonical integer
encoding** (int32 inline, widened 47-bit inline, interned box) and never as
a float. Consequences and pieces:

- `lj_tab.c`: `hashi64()` hashes the int64 value for all three encodings;
  lookups compare by value (`tab_findi64`: node keys are decoded, so no box
  needs to exist for a lookup and a float key with an integral value finds
  the integer node). `lj_tab_get/set/keyindex/getinth/setinth/countint`
  follow; a new key keeps the caller's encoding (the parser keys its
  constant table `fs->kt` by the boxed literal object and `fs_fixup_k` must
  get that object back as a GC constant). `lj_tab_seti64(L, t, v)` is the
  store entry by value (also the JIT's NEWREF for an IRT_I64 key).
  `lj_meta_tset` no longer floats integer keys before `lj_tab_newkey`.
- `next()` takes a float key as a float only, like PUC's `findindex()`:
  `next(t, 2^40)` is an "invalid key to 'next'" although `t[2^40]` is
  `t[1<<40]`; `lj_obj_equal()` would have equated them (int/float numeric
  equality), so the traversal compares float keys by raw bits.
- Bytecode dump: `BCDUMP_KTAB_I64` for widened/boxed keys and values in
  template tables (`bcwrite_ktabk` wrote the low word of a widened value).
- GC: a boxed integer is a value. Weak tables mark boxed keys and values
  whatever their mode and `gc_mayclear()` never drops them. `lj_i64_box()`
  resurrects a dead box found during the sweep (`flipwhite`, like
  `lj_str_new`): a box that is only referenced from the intern hash between
  the atomic phase and its sweep used to be handed out and then freed.
- JIT recorder (`rec_idx_key`): keys are normalised under guards the same
  way -- a float with an int32 value becomes `CONV INT NUM CHECK`, a larger
  integral float `CONV I64 NUM` plus an equality guard on the way back, a
  non-integral float is guarded `FLOOR(key) != key`, and an IRT_I64 key is
  guarded outside the int32 range (the canonical-encoding rule, which a key
  computed by a 64-bit op cannot promise by its type). Integer keys stay
  IRT_INT/IRT_I64 for HREF/HREFK/NEWREF (no more `CONV NUM INT` for hash
  keys); a constant int64 key becomes the widened word (KINT64) or the
  interned box (KGC udata, kept alive by the trace). The normalised key is
  `RecordIndex.nkey`; metamethods still receive the original key (PUC
  passes `2^40` as a float to `__index`).
- Backends: `asm_href` hashes int32/int64 keys by value (`hashi64`) and
  compares int32 keys and widened constants as raw TValue words; a
  non-constant int64 key decodes each node key in the chain (int32 inline,
  widened payload, or `UDTYPE_I64BOX` payload) and compares the value.
  `asm_hrefk` compares the widened word or the box pointer. `ir_khash`
  hashes integer constants and boxes by value. NEWREF with an IRT_I64 key
  calls `lj_tab_seti64`. `rawget`/`rawset` accept int64 arguments.
- Alias analysis (`aa_ahref`) is unchanged: INT, I64 and NUM keys are
  different types and, under the guards above, cannot name the same node.

Test: `tests/d54/i64_04_keys.lua` (all encodings as keys, float-key
normalisation, next/pairs, template tables in mode R, metamethod keys,
sparse int32/negative keys, constant and variable int64 keys in hot loops,
keys crossing encodings, weak tables, 20000 boxed keys under GC pressure).
`-jv`: 40 traces compiled; the aborts are stock ones (mixed sparse/dense
table in the weak-table loop, fast functions with int64 arguments).

### Gates (commit 87dfc75e, 2026-11-16)

`tests/ci-box.sh` on both boxes, identical: modes A+B 81 PASS / 0 FAIL / 13
XFAIL / 0 XPASS, mode B at opt 0-3 184 PASS / 0 FAIL / 4 XFAIL (math_os_01 B),
mode R 47 PASS, C API 34 + i64 14/14, fuzz 160/160. The new test runs in
all four modes (the template table with int64 keys covers dump/reload).

Benchmark gate `tests/bench/run.sh`, median of 3 (the x64 box was shared
during the FFI and PUC arms of this run; the JIT arm is unchanged against
part 2):

| bench (arm64, the arm64 build box) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 FNV-1a-64, 10 MiB | **16.5 ms** (1.09x FFI) | 12036.3 ms | 15.2 ms | 289.0 ms |
| B2 1e6 64-bit values | **1520.6 ms, 79 MB** | 2667.7 ms, 522 MB | 622.8 ms, 31.6 MB | 547.6 ms, 16.4 MB |
| B2b 1e6 ~2^41 values | **130.7 ms, 8.2 MB** | 383.9 ms, 79 MB | 125.7 ms (float) | 176.0 ms |
| B3 int32 control (fnv / table) | **23.7 / 212.9 ms** | 4315.9 / 672.7 ms | 37.9 / 200.2 ms | 309.1 / 255.3 ms |

| bench (x64, the x64 build box NUC) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 | **30.2 ms** | 21419.0 ms | 36.5 ms | 3152.1 ms |
| B2 | **3124.3 ms, 79 MB** | 7597.5 ms, 522 MB | 5402.4 ms, 31.6 MB | 3172.1 ms, 16.4 MB |
| B2b | **662.3 ms, 8.2 MB** | 1253.8 ms, 79 MB | 1253.2 ms (float) | 728.0 ms |
| B3 | **47.6 / 955.6 ms** | 15895.6 / 1886.5 ms | 99.1 / 872.8 ms | 1323.5 / 1001.0 ms |

Checksums on both arches, JIT == -joff == PUC: B1 343592796160, B2
4047905256, B2b 299440, B3 1196193376. No regression against part 2 (arm64
B1 16.5 / B2 1520.6 / B2b 130.7 / B3 23.7 ms; x64 B1 30.2 / B2 3124.3 / B2b
662.3 / B3 47.6 ms).

## Step 4 (2026-11-16, branch `i64-ffuncs`): the standard library with int64, GC drive, GC stress

Characterisation first (`tmp/probef2.lua` against PUC): the interpreter
itself was wrong in several library paths before any recorder work.

### Interpreter

- `lj_lib_checknum/checknumber/checkint` take boxed and widened 5.4
  integers (`checknum` read a widened value through its low word; a box was
  "number expected, got number"); `checkint` saturates an integer outside
  int32 (positions clamp as in PUC, counts are rejected by the callee).
- `math.min/max` are finished in C with exact 5.4 comparisons (int64 vs
  float via `lj_i64_cmpnum`) and return the winning argument as is; the asm
  fast path cannot take a box, and `FFH_RETRY` would only come back.
  `math.floor/ceil` return an integer argument unchanged (`2^60+1` lost its
  `+1` through a double). `math.fmod(x, -1)` is 0 (`mininteger % -1`
  trapped), zero divisor wording "zero". `math.random` returns integers of
  any size.
- `..` and `table.concat` format boxed integers (and `table.concat` no
  longer prints the low word of a widened one); `string.format("%q")`
  prints them (mininteger as `0x8000000000000000`, like lstrlib).
- String to number (`STRSCAN_OPT_TOI64`, `lj_strscan_number64`): integer
  syntax yields an integer of any size (decimal overflow becomes a float,
  hexadecimal wraps modulo 2^64, also for more than 16 digits); used by
  arithmetic coercion (`"1152921504606846976" + 0`), `tonumber` (with an
  explicit base the value wraps, as l_str2int does) and the argument
  checkers. `%d` of a float outside int64 errors on arm64 too (the
  conversion saturates there).
- 5.4 wording and checks: `string.rep` "resulting string too large" before
  allocating (a saturated count used to run into "not enough memory"),
  `string.char` "value out of range", `table.insert` "position out of
  bounds" (new bounds check).
- **GC drive:** pure int64 arithmetic allocates boxes and nothing else, and
  the VM's arithmetic fallbacks had no GC check: a 300k-iteration xorshift
  loop under `-joff` went from 1 MB to 131 MB. `lj_meta_arith` and
  `lj_meta_bitop` now run a GC step after a boxed result (`L->top =
  curr_topL(L)` like `lj_meta_cat`); the arm64 VM reloads BASE after both
  helpers because the step may move the stack (x64 already did).

### Recorder

- `lj_ir_tonum` converts an IRT_I64 ref to a double (what `lj_lib_checknum`
  does), which makes the FP math fast functions (sqrt, exp, sin, log,
  atan2, ldexp, ...) take int64 arguments. `lj_ir_tostr` formats one
  exactly through the new `lj_strfmt_i64` IR call: `tostring()`, string
  concatenation and `string.format("%s")`; `%d/%i/%x/%X/%o/%u` go through
  `lj_strfmt_putfxint`.
- `math.abs` → `lj_i64_abs` (wraps for mininteger; the result stays I64,
  since |v| of a value outside int32 is outside int32). `math.min/max` with
  integer arguments only → `lj_i64_min/max`, result narrowed back to int32
  under a guard when the runtime result fits; mixed int64/float arguments
  stay in the interpreter.
- `tonumber`: an int64 argument is returned as is; a constant string folds
  to the exact 5.4 result; a runtime string with integer syntax has no IR
  (STRTO yields a double) and aborts -- which also ends `tonumber("5")`
  compiling to `5.0` where the interpreter returns the integer 5.
- Still NYI: positions/counts given as int64 (`string.sub(s, 2^60)`,
  `string.rep`, `select(2^40, ...)`), `math.min/max` with mixed arguments,
  `string.format` with width/precision on `%s` of an int64.

### GC stress mode

`tests/harness.sh --gc-stress` runs every arm (PUC, -joff, -jon at each
opt level, dump/reload) with `collectgarbage("setpause", 0)`, so a value
that is alive only by luck gets collected under the test. `ci-box.sh` runs
the `i64_`, `close_`, `coro_`, `gc_` and `bits_` tests that way in modes A,
B@0, B@3 and R. Both GC bugs of the day (barrier CSE across LOOP, dead-white
box handed out by the intern hash) would have shown up here.

Test: `tests/d54/i64_05_lib.lua` (library semantics plus hot loops for every
recorder path; `-jv`: 16 traces, the aborts are the documented NYIs).

### Gates (commit 6bd96596, 2026-11-16)

`tests/ci-box.sh` on both boxes, identical: modes A+B 83 PASS / 0 FAIL /
12 XFAIL / 1 XPASS (math_02_random A -- `math.random(0)` now returns an
int64; the known-bad entry is removed in the follow-up commit), mode B at
opt 0-3 188 PASS / 0 FAIL / 4 XFAIL (math_os_01 B), mode R 48 PASS, GC
stress (new) 57 PASS / 0 FAIL / 3 XFAIL, C API 34 + i64 14/14, fuzz
160/160.

Benchmark gate `tests/bench/run.sh`, median of 3 (x64 from a bench-only
rerun: the run inside the gate overlapped another job on the NUC and showed
every JIT arm, int32-only B3 included, 1.5-2x slower with the FFI and PUC
arms unchanged):

| bench (arm64, the arm64 build box) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 FNV-1a-64, 10 MiB | **16.6 ms** (1.05x FFI) | 3995.9 ms (was 12036: the GC step keeps the box heap small) | 15.8 ms | 296.4 ms |
| B2 1e6 64-bit values | **1496.6 ms, 79 MB** | 4508.5 ms, 190 MB (was 522 MB) | 823.0 ms, 31.6 MB | 579.1 ms, 16.4 MB |
| B2b 1e6 ~2^41 values | **148.9 ms, 8.2 MB** | 344.7 ms, 79 MB | 140.7 ms (float) | 175.6 ms |
| B3 int32 control (fnv / table) | **23.0 / 215.2 ms** | 2281.8 / 614.5 ms | 43.7 / 203.5 ms | 307.6 / 276.2 ms |

| bench (x64, the x64 build box NUC) | ours JIT | ours -joff | stock 2.1 FFI | PUC 5.4.7 |
|---|---|---|---|---|
| B1 | **30.5 ms** (1.04x FFI) | 13407.0 ms | 29.2 ms | 1342.0 ms |
| B2 | **3211.6 ms, 79 MB** | 7581.8 ms, 110 MB (was 522 MB) | 2591.2 ms, 31.6 MB | 2153.2 ms, 16.4 MB |
| B2b | **677.8 ms, 8.2 MB** | 1048.6 ms, 15.5 MB (was 79 MB) | 612.1 ms (float) | 727.2 ms |
| B3 | **47.7 / 955.5 ms** | 7844.4 / 1920.0 ms | 96.9 / 857.3 ms | 1310.3 / 997.6 ms |

Checksums on both arches, JIT == -joff == PUC: B1 343592796160, B2
4047905256, B2b 299440, B3 1196193376. JIT arms unchanged against part 3;
the interpreter arms got faster and leaner (arm64 B1 -joff 12036 -> 3996
ms, B2 -joff 522 -> 190 MB) because the GC now runs during box arithmetic.

## B2 after step 4 (2026-11-16, branch `b2-sort`): where the gap is

B2 split on arm64 (ms, PUC / ours -jon before / after this branch):
fill 1e6 xorshift values into a table 24 / 137 / 122; sum 4 / 2 / 2;
`table.sort(t, function(a, b) return a < b end)` 526 / 790 / 708;
`table.sort(t)` 151 / 564 / 402.

- The fill is one box allocation plus one intern probe per store (PUC
  stores the int64 inline). The insert now reuses the lookup probe's slot
  (one pass instead of two); the allocation and the GC sweep of 1e6 boxes
  remain.
- Both sorts are memory bound: every comparison dereferences two boxes
  that are scattered over 1e6 allocations, where PUC compares inline
  TValues. The VM now compares two integers of any encoding inline in
  ISLT/ISGE/ISLE/ISGT (no C call); `lua_lessthan` (the default comparator)
  compares exactly instead of via `lj_meta_comp` -- and compared widened
  values by their low word before, a correctness bug.
- What is left (1.35x PUC on the comparator sort, 2.7x on the default
  sort, 5x on the fill) is the boxing itself: a value above 2^47 is an
  object. Closing it means the 16-byte TValue alternative from the ADR, not
  an incremental change; B1/B3 (values inside 47 bits, JIT) are at the FFI
  yardstick.

Also found by the new test: `(lua_Number)(int64_t)n == n` accepts `2^63`
on arm64 (the conversion saturates), so `2^63 & 1`, `math.floor(2^63)` and
the parser's constant folding treated it as an integer; `lj_i64_numtoint`
checks the range explicitly. Compare errors said "userdata" for a boxed
integer; `lj_typename` says "number".
