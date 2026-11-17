# Classic benchmark regressions — diagnosis (2026-11-17)

Diagnosis only; no source/VM fix. Tools: `tests/lib/perf-diag.py` (`-jv`,
`-jdump=+rsi`, trace counts/reasons), `tests/lib/perf-time.py` (stock/ours
`-jon`/`-joff` medians), probes `tests/lib/perf-strkey.lua`,
`tests/lib/perf-knuc.lua`. Sources/workloads as in
`docs/bench-classic-2026-11-17.md`.

## Baseline rerun after the arm64 fix

`6e4d7bb9` removed the arm64 checkint TMP0 clobber. arm deltablue rerun
(stock 3593.4 ms, ours 4709.3 ms, ratio 0.76): it improved from 5685.8 ms
(0.62) at the pre-fix measurement but remains a >10% finding (~31% slower).
x64 is unchanged (19042.8 vs 27450.5, 0.69). x64 `checkint` still carries the
widened-range test added in `cb2f6da`, but these benchmark hot traces contain
no bit/tobit fast-function calls (`calls=0`, `lj_i64=0`), so it is not the
cause of deltablue/spectral/k-nucleotide. It remains a possible cost on
int-heavy fast paths only.

## deltablue (both arches) — cause: missing-metamethod trace aborts

`-jv` x64: stock has 43 reason groups, 334 traces, **0** missing-metamethod
aborts. Ours has 65 groups, 468 traces, and **16+ per source line** of
`missing metamethod at deltablue-locals.lua:721` (plus its resulting
blacklists at lines 164/222/608). arm shows the same missing-metamethod
pattern (our first arm run: 120 such lines vs stock 0).

Source line 721 is `if d:output().mark == mark then` inside
`Planner:addPropagate`; the lookup is a class-instance table with an
`__index` chain. Our recorder takes `LJ_TRERR_NOMM` (`src/lj_record.c:1876`,
`lj_record_idx` non-table/__index chain), where stock traces the same index
and keeps the loop compiled.

Hottest loop trace (max mcode): x64 stock IR 825 / mcode 2157 / guards 464 /
SLOAD 2; ours IR 462 / mcode 1151 / guards 253 / SLOAD 4. Ours forms a smaller
trace, while the extra NOMM aborts blacklist hot loops and force interpreter
fallback. Account is dominated by trace loss, not by a slower loop body.

**Hypothesis:** the fork's 5.4 `__index`/metamethod-chain handling in
`lj_record_idx` (or `lj_record_mm_lookup`) rejects the class-table
`__index` chain at `d:output().mark`, whereas stock recurses it; fix that
recorder path so the stock-sized loop trace can form. Arm deltablue has the
same mechanism; the checkint fix only removed part of its overhead.

## spectral-norm (x64) — cause: integer loop arithmetic + guards/CONV

Hottest loop trace: stock IR 46 / mcode 70 / guards 11 / CONV 2; ours IR 51 /
mcode 88 / guards 20 / CONV 7. The IR bodies show the mechanism:

- stock uses `num SLOAD`, `num ADD/SUB/MUL`, one `num CONV` for the int index;
- ours has `int SLOAD`, `int ADDOV/SUBOV/MULOV` (four overflow guards per
  loop) and five `num CONV ... num.int`, plus `int CONV ... int.num check`
  on the float accumulator.

This is the 5.4 integer-for-loop model: `i/j` are native integers, arithmetic
stays integer with overflow guards, then converts to float for the
accumulator. Stock ran the same expression in floats. Extra guards and
conversions cost ~29%.

**Hypothesis:** for a numeric loop whose integer result is immediately used
as float (`a + x[j]*A(i,j)`), record/emit the expression as float or fuse the
int→num CONV chain and drop redundant OV guards; alternatively keep loop
locals float when all arithmetic consumers are float. VM recorder/IR, not a
benchmark change.

## k-nucleotide (x64 finding; arm rerun not a finding) — cause: table/__index interpreter path

x64: `-jon` stock 63.0 ms vs ours 73.1 (0.86); `-joff` 83.6 vs 94.1 (0.89).
So this is not only a JIT trace problem — the interpreter/library path is
slower. Hot traces are nearly identical (stock IR 67/mcode 202/guards 35/CONV 1;
ours IR 66/mcode 185/guards 33/CONV 0). Instrumented `kfrequency` stages
(`tests/lib/perf-knuc.lua`): the long-fragment counts are slower in ours
(K=12 18.3→20.9 ms, K=18 26.4→31.0 ms at the x64 measurement).

Micro `perf-strkey.lua` (string.sub + interned string key + `__index=default`
function): ours is slower in `-joff` for K=3 ~15%, K=12 ~8%, K=18 ~9%, and in
`-jon` mostly at K=3; a plain table without `__index` is only ~5% slower.
Both stock and ours intern strings, so interning policy is not the delta; the
`__index`-function miss path and table string-key lookup are.

arm rerun at `6e4d7bb9` (`BENCH_ONLY=k-nucleotide`): stock 24.4 ms, ours
19.2 ms (1.27, ours faster). The earlier arm 0.88 figure was load/noise; the
x64 finding stands and arm's JIT hides the interpreter table-path cost.

**Hypothesis:** the fork's table GET miss + function `__index` path (used by
`freq[c] = freq[c]+1` for unseen substrings) carries extra checks/guards
relative to stock 2.1; optimize `lj_record_idx`/`lj_meta_index` or the
interpreter table-get path for interned string keys with `__index` functions.
Not a string-interning change.

## Checked, not the cause here

- arm64 checkint TMP0 clobber: fixed; deltablue improved but remains slow.
- x64 checkint widened-range test: still present, but no bit/tobit fast calls
  in these hot traces.
- Integer/float `/` paths: spectral's `/` is already float; the extra cost is
  int arithmetic + CONV/OV guards, not DIV.
- String interning: both stock and ours intern; k's delta is the table/__index
  lookup path, not interning itself.
