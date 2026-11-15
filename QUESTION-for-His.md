# Question for His — lifting the int64 blocker the "accepted way"

From: pica (LuaJIT-5.4 port session) · 2026-11-15
Repo: `/home/mfritsche/src/LuaJIT-5.4` (branch `main`, bare origin `~/src/git/LuaJIT-5.4.git`)
Plan/ADR: `docs/plan.md` (ADR-001), status log: `docs/phase0-status.md`

## Problem

LuaJIT 2.1 cannot represent Lua 5.4 integers exactly. `TValue` is 8 bytes,
NaN-boxed, and dual-number mode stores integers as **int32**:

- `src/lj_obj.h`: `setintV(TValue *o, int32_t i)` writes `o->i` (int32) and sets
  `LJ_TISNUM`; `setint64V` silently demotes to int32 *or* a double;
  `intV(o)` returns `int32_t`.
- `LJ_GC64` layout: 47-bit payload + 17-bit tag in one u64 (no room for int64).
- non-GC64 layout: 32-bit value + 32-bit tag (same problem).
- Stack slots are 8 bytes everywhere: `BASE+RA*8` in the `.dasc` backends
  (~41 slot sites in `vm_arm64.dasc`, ~192 in `vm_x64.dasc`, plus x86/arm/ppc/
  mips), `sizeof(TValue)` arithmetic in 22 C sites, and snapshot/restore in
  `lj_snap.c`.

Consequently these 5.4 items are unimplementable today and sit in
`tests/known-bad.tsv`:

- `//` (integer floor division) — not even parseable
- 5.4 bitwise semantics: mod-64 shift counts, logical `>>`, negative counts
  reverse direction
- `math.maxinteger` / `math.mininteger` (cannot be exact doubles)
- exact large-int arithmetic, wrapping mod 2^64, exact int↔float comparison
  (5.4: `9007199254740993 == 2^53` is false)
- int constants in the 5.4 dump format (EXTRAARG)

## What I tried

- Mapped a full migration (constants + accessors → C users of `sizeof(TValue)`
  → arm64 VM first, then x64 → snapshot/deopt), documented as ADR-001a in
  `docs/plan.md`: **16-byte TValue**, low word keeps today's NaN-boxing, new
  internal tag `LJ_TISNUM64`, int64 in the high word, every slot address
  `*8 → *16`.
- Started a branch that changes the value model and discarded it rather than
  commit something I could not verify; `main` is green and buildable.
- Kept everything independent of int64 and pushed it: int/float literal split
  (scanner, parser float-constant table, fold rules, JIT recorder), 5.4 float
  rendering, table borders, `__len`/`__pairs`/`__name`, utf8, `string.pack`,
  `%q`, gmatch, os/io, debug upvalues, math.type/tointeger/ult, C API surface.
- Rejected alternatives in the ADR: keep 8 bytes with ints ≤2^53 (breaks 5.4);
  box large ints as GC objects (value semantics everywhere); PUC-style split
  tag/value arrays (rewrite of all type dispatch).

## Evidence

Harness is the acceptance criterion and it is green on what is implemented:

- `tests/d54` (30 files, modes A/B/R): PASS 71, XFAIL 19, FAIL 0
- full corpus incl. upstream PUC-Lua 5.4.7 suite: PASS 115, XFAIL 36, SKIP 12,
  FAIL 0
- C API harness `tests/capi`: 34/34
- mode-B differential fuzz at `jit.opt.level` 0–3 with GC pressure: green
- latest end-to-end run on a clean aarch64 box (`arm-box`, fresh copy):
  A+B PASS 41, mode B 0–3 PASS 120, mode R PASS 30, capi 34/34, fuzz 160/160

Reproductions of the gaps (PUC 5.4.7 vs ours): `tests/d54/numeric_01_types.lua`
(`math.maxinteger` → nil), `numeric_03_idiv.lua` (parse error), `bits_01_ops.lua`
(`1 << 64` → 1 instead of 0, `-1 >> 1` → int32 max instead of int64 max),
`fmt_01_format.lua` (`%d` of `math.maxinteger`).

Workflow constraint discovered this session: local builds on pica are refused by
an external guard (`make` → exit 97, "Do not build locally"), so every
verification is an `arm-box` (escher aarch64) or `build-box` (born x86_64) run;
`tests/ci-box.sh` + vendored `tests/ref/dist/lua-5.4.7.tar.gz` make that
self-contained (build-box is currently blocked by a card measurement window on
dirac).

## One concrete question

The previous turn deemed this a blocker; how do I lift it **the accepted way**?

Specifically: do I proceed with the 16-byte `TValue` (ADR-001a) as documented,
or is there fleet precedent I should reuse instead — an existing 16-byte-value
LuaJIT fork/branch or known-good value-model patch — or a decision to defer
int64 and keep the 8-byte value with documented 5.4 gaps? If 16 bytes is
accepted, please also state the migration order you consider safe (what must
land together per backend so the tree stays buildable and the harness green).
