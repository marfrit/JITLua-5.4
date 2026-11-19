# Array-part limit under GC64 (asize64)

Decision: under `LJ_GC64` the table array part may have up to `2^31-1` slots
(`LJ_MAX_ASIZE = (1u<<31)-1`, `LJ_MAX_ABITS = 31`), following PUC 5.4's
`MAXABITS = 31`. Non-GC64 builds keep the old `2^27+1` limit unchanged (`#if`
in `src/lj_def.h`). `tests/corpus/puc54/heavy.lua` no longer ends in "table
overflow": it ends in "not enough memory" like PUC, only the stop size differs.

## Why 2^31-1 and not 2^31

`GCtab.asize` is a `uint32_t`, and allocation sizes are `GCSize` (64 bit under
GC64), so both values are representable. The binding constraint is the JIT and
the Lua library index arithmetic:

- `IRFL_TAB_ASIZE` is loaded as an `IRT_INT` field (`lj_record.c`,
  `lj_opt_fold.c` folds it with `INTFOLD`). An `asize` of `2^31` would appear
  as a negative int32 in those paths; `2^31-1` (INT_MAX) stays positive.
- Array bounds checks (`IR_ABC` / `IR_ULE`, the VM fast paths) already compare
  unsigned (`jae` / `CC_LS`), so they are correct for any `uint32` asize. The
  signed folds around the same value are what need the positive range.
- Keys and lengths stay int32: the largest array key with asize `2^31-1` is
  `2^31-2`, so `t[n]`, `#t`, `ipairs`, `table.concat` (`int32_t` end),
  `table.move` and `unpack` indices all remain representable. A key at
  INT_MAX cannot be an array slot with this limit and stays in the hash part,
  exactly as the runtime `inarray()` check does. It would need a 16 GiB array,
  which is not reachable under the boxes' caps (RLIMIT 4 GiB / 14 GiB, cgroup
  8 GiB on arm); the divergence from PUC at that single extreme is deliberate.

## Limits and size computations audited

- `src/lj_def.h`: `LJ_MAX_ABITS`, `LJ_MAX_ASIZE` (`#if LJ_GC64`); the file now
  includes `lj_arch.h` so `LJ_GC64` is defined before these limits are chosen
  (`lj_def.h` historically precedes `lj_arch.h` in `lj_obj.h`).
- `lj_tab.c` `newtab` / `lj_tab_new` / `lj_tab_new_ah` / `lj_tab_new1`:
  `lua_createtable` path checks `asize > LJ_MAX_ASIZE` before `lj_mem_newvec`.
- `lj_tab_resize` / `lj_tab_reasize`: growth limit; `oldasize*sizeof(TValue)`
  and `asize*sizeof(TValue)` are evaluated in `size_t` (64 bit under GC64,
  `TValue` is 8 bytes), so no 32-bit product overflows. The shrink-reinsertion
  loop casts `i` to int32 only for `i < 2^31-1`, which this limit guarantees.
- `rehashtab` counting: `countarray` scans bins up to `LJ_MAX_ABITS`; `top =
  2u << b` stays `uint32` (b <= 30) and is clamped to `asize-1`.
  `countint` now uses a `uint64_t` comparison (`(uint64_t)i64 < LJ_MAX_ASIZE`)
  so a negative or >2^32 integral float key is not miscounted through its
  truncated `uint32` form. `bestasize` uses `uint64_t` for `2*nn` and
  `2*sum`, bounds `b < LJ_MAX_ABITS` (no bins[] overrun), and under GC64 clamps
  the bin-30 proposal `2^31+1` to `LJ_MAX_ASIZE`; under non-GC64 it keeps the
  old oversized-proposal-then-overflow behaviour.
- `lj_mem_*` (`lj_gc.h`): `lj_mem_newvec`/`reallocvec`/`freevec` multiply by
  `sizeof(t)` (size_t) before the `GCSize` cast, no 32-bit overflow.
- Colocated arrays are limited to `LJ_MAX_COLOSIZE = 16`; `sizetabcolo` only
  ever sees that range.
- GC accounting (`lj_gc.c`): `sizeof(TValue) * t->asize` and the separateudata
  sum are evaluated in `size_t`.
- JIT: `rec_idx_abc` emits unsigned `IR_ABC`/`IR_ULE` for the asize field;
  x86 and arm64 `asm_compmap` map ABC to unsigned conditions; `IR_ALEN`
  returns the computed length (<= INT_MAX). No signed narrowing change needed
  because asize stays positive int32. The address of a slot is another
  matter, see "Index scaling" below.
- Interpreter fast paths (`vm_x64.dasc`, `vm_arm64.dasc`: TGETV/TGETB/TGETR,
  TSETV/TSETB/TSETR, TSETM, ITERN/ITERC, ipairs_aux, vm_next) compare with
  unsigned branches (`jae`, `bhs`, `ja`) against the 32-bit asize. The index
  scaling was 64 bit on arm64 only; x64 needed the fix below.
- 5.4 integer keys: `inarray()` uses `(MSize)key < asize`; int32 keys stay
  array slots, int64 keys above INT_MAX go to the hash part; the two paths
  (interpreter and recorder) use the same threshold.
- `table.move`/`table.concat`/`unpack`/`#`: indices/end are int32 and lengths
  return `MSize`/int32 values bounded by `asize-1` (<= INT_MAX); `table.maxn`
  casts the last slot index (<= 2^31-2) safely.

## Index scaling (review fix)

The first version of this change audited the limits and the comparisons, and
stated that the index was scaled in 64 bit address arithmetic everywhere. It
was not. The old limit of 2^27+1 slots had kept `8*index` below 2^30, and
three places relied on that:

- `vm_x64.dasc`, TGETV/TGETB/TGETR/TSETV/TSETB/TSETR/TSETM: `shl RCd, 3`
  shifts a 32 bit register. From index 2^29 on the product wraps, and
  `t[2^29+n]` read and wrote slot `n`: silent wrong data in the interpreter.
  Now `shl RC, 3`; the three instructions whose `RC` still carries the tag of
  the key (TGETV, TSETV, TSETR) clear the upper half first, which the 32 bit
  shift had done on the side.
- `lj_asm_x86.h` `asm_fusearef`: a constant index was fused as the
  displacement `8*index` in an `int32_t`. `t[2^28+2]` in compiled code
  addressed 2 GiB below the array (SIGSEGV), `t[2^29]` addressed slot 0. A
  constant index is fused only if base offset + `8*index` fits `int32`;
  otherwise it is loaded into a register like a variable index.
- `lj_asm_arm64.h` `asm_aref` and the fused load/store operand: the same
  product in an `int32_t`, wrapped before the immediate-range checks, so
  `t[2^29]` in compiled code addressed slot 0. Computed in 64 bits now.

`ipairs_aux`, ITERN and `vm_next` on x64 and every arm64 interpreter path
already used 64 bit address arithmetic.

`tests/lib/array-huge.lua` covers this with a table of 2^29+17 array slots
(about 4.3 GiB): variable and constant indices above 2^28 and 2^29 in the
interpreter and in hot functions, `next`/`pairs`, `table.unpack`,
`table.concat` and `table.move` at a high index. It runs with `-joff` and
`-jon` as a stage of `tests/ci-box.sh` and skips itself when less than 6 GiB
is available; it is not part of the public CI workflow because of its size.
Before the fix: 11 failed checks with `-joff` and a crash with `-jon` on
x86_64, 3 failed checks with `-jon` on aarch64.

## Test

`tests/d54/tbl_04_array_limit.lua` (modes B,R; PUC has no `require"table.new"`):
preallocates `2^27+1` array slots (one above the old `2^27+1` asize limit),
checks `#t`, `t[n]` and `ipairs` termination, then runs a hot JIT loop over the
top of that array (loads and stores) and finally checks that one slot past the
new limit reports "table overflow".

Red on the unchanged tree (x86_64, both arms exit 1 before any "above" line):

```
below	true	true
lua: table overflow
stack traceback:
	[C]: in function 'table.new'
	tests/d54/tbl_04_array_limit.lua:32: in main chunk
```

Green after the change on x86_64 and aarch64, modes B and R (`-jon` vs
`-joff`, and dump/reload), print `below true true`, `above true true true`,
`jit true true true`, `limit false table overflow`, `done`.

## heavy.lua

`puc54/heavy.lua` (`toomanyidx`) under an address-space cap, measured on both
arches:

- 4 GiB (`--include-heavy` default): PUC stops with "not enough memory" at
  `#a=134217728`; LuaJIT now also stops with "not enough memory" at
  `#a=268435456` (`collectgarbage'count'` ~2.15 GiB on both). Before this
  change LuaJIT ended with "table overflow" at `#a=201326592`.
- 14 GiB (x86_64, a 14 GiB box cap): PUC stops at `#a=536870912`; LuaJIT at
  `#a=1073741824` (~8.59 GiB counted on both sides). This exercises the
  bin-30 `bestasize` clamp and the failure of the following `2^31-1`-slot
  allocation.

The row stays in `tests/known-different.tsv` (IMPL-DEFINED): same error class,
different stop size and per-MiB counters.

## Benchmarks

Classic array-heavy set, base `f8c70a23` vs head, built and run in one pinned
x86_64 box job, interleaved, median of 7 (`BENCH_REPS=7`):

| benchmark | base ms | head ms | base/head |
|---|---:|---:|---:|
| nbody | 8.0 | 8.0 | 1.001 |
| spectral-norm | 32.2 | 32.2 | 1.001 |
| fannkuch-redux | 114.5 | 114.4 | 1.001 |
| scimark | 29573.3 | 29573.1 | 1.000 |

No regression.

## Gates

- `x64-box sh tests/ci-box.sh`: all stages passed (x86_64).
- `arm-box sh tests/ci-box.sh`: all stages passed (aarch64).
- `ci-local.sh --sanitizers-only` on both arches: `ci-local: OK` (ASan+UBSan;
  the new test's ~1 GiB preallocations run under the same cap/no cap as the
  rest of d54).

Non-GC64 note: the `#if LJ_GC64` branches compile to the old macros for
32-bit targets; the x64 build with `LUAJIT_DISABLE_GC64` already fails its
pre-existing `GChead`/`GCproto` static-layout assertion on base `f8c70a23`
(5.4 fork layout), so that configuration was not runtime-checked here.
