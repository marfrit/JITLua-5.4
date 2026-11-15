# ADR-001b — boxed, interned int64 (spike; decision belongs to Markus)

Status: **spike step 1 landed** (C-side box + intern + C display paths, verified by
a C test); Lua-visible use is blocked by step 2/3. ADR-001 (16-byte `TValue`)
demoted to documented fallback. Second opinion: `ANSWER-from-His.md` (His, plus
Markus addenda 1 and 2).

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

His's precedent check: there is no 16-byte-value LuaJIT branch or patch anywhere in the fleet, and
deferring int64 entirely does not meet MISSION §2 goal 1. Staging the int64 work is fine and is what
`tests/known-bad.tsv` already records.

## What the spike must show (arm64 only, via `arm-box`)

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

Each step: `arm-box -t 1200 sh tests/ci-box.sh`. Step 1 verified: modes A+B
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

x64 (born) is NOT complete. Shifts work, but a runtime BC_IDIV (`local a=7
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
