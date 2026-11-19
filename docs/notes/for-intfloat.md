# spectral-norm: SLOAD flags and trace count (2026-11-19)

Scope: why ours emits `RI`/`TI` SLOADs where stock 2.1 emits `CRI`/`CI`, and
why the reduced spectral-norm inner loops produce 6 traces instead of 4. Is
any of it provably redundant for 5.4 semantics?

Tools: `-jdump=-bm` (trace + IR, no bytecode/mcode) over
`tests/tmp-spectral-dump.lua` (N=200, the Av/Atv inner loop), stock built
from the pinned `.dlcache/bench/luajit-63c8f1a9.tar.gz`; interleaved medians
from `tests/bench/spectral-measure.py` in one job per arch.

## Where the flags come from

`src/jit/dump.lua` renders the `SLOAD` op2 bits:
`P`=PARENT, `F`=FRAME, `T`=TYPECHECK, `C`=CONVERT, `R`=READONLY,
`I`=INHERIT, `K`=KEYINDEX (`src/lj_ir.h`).

- Ours `RI` = READONLY|INHERIT, `TI` = TYPECHECK|INHERIT.
- Stock `CRI` = CONVERT|READONLY|INHERIT, `CI` = CONVERT|INHERIT.

Stock runs single-number: the `FORL` slots hold doubles and a narrowed int
loop counter is loaded with `IRSLOAD_CONVERT`. Ours is the 5.4 dual-number
model: an integer loop counter is already an integer in the slot, so no
CONVERT; instead `rec_for_loop` (`src/lj_record.c`) adds `IRSLOAD_TYPECHECK`
whenever the index/bounds may be int or float at runtime, and `READONLY`
when the slot type already matches (omit the slot store). The flags are the
two number models' way of guaranteeing the same runtime type, not extra
checks layered on top of a working single-number path.

## Where the extra traces come from

The inner loop `a = a + x[j]*A(i,j)` starts with `local a = 0` (an integer)
and becomes a float on the first iteration (the product is float). A trace
recorded at loop entry sees `a` as `num` (trace 2); its `num SLOAD #10 T`
exits when a later entry still has `a` as an integer. That exit is recorded
as a side trace (trace 4), which converts `a` to `num` and runs the loop;
its loop-end exit produces one more prologue side trace (trace 5). Stock has
no int type, so `0` is already a double and the single loop trace covers
every entry.

The integer arithmetic in `A()` (`i+j-1`, `ij*(ij-1)`) is 5.4 integer
arithmetic that wraps on overflow, so the recorder emits `ADDOV`/`SUBOV`/
`MULOV` guards and lets the interpreter retry on overflow; a float-only
model has no such step. The `num CONV ... num.int` nodes are the required
int->float conversions where a float operand (`0.5`, `1.0`, the product)
enters the expression.

## Redundancy check

Nothing is provably redundant:

- the overflow guards reproduce 5.4's wrapping integer arithmetic; the loop
  bounds are runtime values (N), so no bound proof removes them;
- the int->num CONVs are at distinct values, so no CSE/FOLD applies; fusing
  or floating the whole expression would change results where the integer
  intermediate overflows;
- the extra side traces encode a local that is an integer at loop entry and
  a float afterwards; LuaJIT's IR has one static type per SLOAD, so the
  side trace *is* the mechanism, not an over-specialization.

Hot-loop edge tests (`tests/d54/numeric_07_hot_intfloat.lua`, 14 int/float
accumulator and `//`/`%`-with-negatives cases) match the PUC 5.4.9 reference
under -joff, -jon, -O0 and -O3 on x64, so the extra work buys the correct
5.4 result.

Separately, integer `for` bounds outside int32 become floats
(`lj_meta_for`, ADR-001b): `for i=2147483646,2147483649` gives floats where
PUC gives integers. That is the documented VM limitation (FORI/FORL only
handles int32 natively), not the spectral overhead.

## Measurement (interleaved, one job per arch)

spectral-norm 200, median of 9 (x64) / 7 (arm64):

| arch | stock | ours | stock/ours |
|------|-------|------|-----------|
| x64  | 15.4 ms | 16.0 ms | 0.962 (~4%) |
| arm64 | 4.0 ms | 4.0 ms | 1.008 (parity, noisy) |

The `>10%` figure in `docs/bench-classic-2026-11-17.md` (stock 15.5, ours
21.9) no longer reproduces on this tree. Conclusion: no source change; the
DIFFERENCES perf row is corrected to drop spectral-norm.
