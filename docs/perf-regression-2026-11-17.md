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

## Outcome (Session 54, branch `jit-index-chain`)

Both hypotheses above were verified before changing code; both root causes
are elsewhere than stated.

### deltablue — NOMM abort was a miscompilation in lj_opt_mem.c, not the `__index` chain

A minimal `class()` repro with a two-level `__index` chain records cleanly in
ours and stock. `-jdump=+a` (IR of aborted traces) shows what really aborts:
in `OrderedCollection:removeFirst` (`local e = self.elms[#self.elms]`) the
load is missing from the IR and `d` is a constant nil, so `d:output()` has no
metatable to look up. The IR before the abort is

    0447 >  tab TNEW   #0 #0        -- todo.elms = {}
    0456    p64 NEWREF 0447  +1     -- todo:add(c): elms[#elms+1] = c
    0457    tab HSTORE 0456  0113
    0461    int ALEN   0447  nil    -- removeFirst: #elms
    0469    p64 AREF   0468  0461
    0470    nil ASTORE 0469  nil    -- elms[#elms] = nil  (the load is gone)

`fwd_ahload()` const-folds a load from a freshly allocated table to nil unless
a NEWREF "with a number key" may have landed in the array part. Stock 2.1
converts every integer hash key to IRT_NUM, so `irt_isnum(key)` was the test.
This fork keeps hash keys as IRT_INT / IRT_I64 / an interned box constant
(ADR-001b), so the int-key NEWREF looked like a string key. The same stock
assumption sat in `lj_opt_fwd_alen` (HSTORE with "numeric key" limits ALEN
forwarding), `lj_opt_fwd_href_nokey` and the TDUP const-fold path (which also
fed an IR_KINT64 key to lj_ir_kvalue, i.e. an FFI cdata). Probes
(`tests/d54/jit_02_tabkey_alias.lua`): `#t` after `t[4] = nil` with 4 in the
hash part was wrong in 2943/3000 iterations with -jon -- a silent wrong result,
not an abort. Fixed in `56f9eea4`: NOMM aborts 74 -> 0 (arm), 0 (x64);
all probes 0 wrong on both arches.

That removed the abort but not most of the slowdown (arm 0.76x -> 0.73x..0.85x
run to run; x64 0.69x -> 0.83x). What the rest is NOT, each measured:

- not `__index`: method call through a 2-level chain + int field compare,
  int field RMW, polymorphic dispatch, push/pop with `#`, object construction,
  Strength compares -- all identical to stock (`tmp/micro.lua`, arm);
- not code quality: IR per recorded bytecode is identical across the whole
  trace set (HLOAD .230/.237, HREFK .230/.238, FLOAD .389/.401, guards
  .96/.99; 185 vs 175 traces);
- not data shape or GC: 146.5 bytes per 8-push table in both, same push-loop
  IR, bytes allocated 3.79 vs 3.76 GB, GC steps +13%, `setpause 1000` helps
  both by the same 0.4 s; max RSS equal;
- not startup (+140 us) and not the profiler lying (vmstate attribution
  checked with a jit.off function and an exit-to-interpreter loop).

What it IS: trace selection. `-jp=v` has ours 81% compiled / 17% GC and
stock 61% compiled / 25% interpreted / 13% GC, i.e. ours compiles more and
runs longer. The biggest loop trace in ours roots at the chainTest loop
(`:830`, IR 1056) with the `:720` while-loop unrolled inside it; stock roots at
`:611` and `:720`. `-Ohotexit=5,tryside=8` moves ours from 0.85x to 0.94x and
stock not at all; `-Ohotloop=20` similarly. Linked side-trace entries bypass
lj_trace_exit, so the exit counter (2.3k-4.3k exits per run, both) does not
see the live trace graph. Next instrument: a per-trace entry counter in the
exit stubs / JLOOP, run under `setarch -R` so trace numbers are stable, and
compare the dynamic graph. Open.

### k-nucleotide — not the `__index` miss; io.lines() and the x64 int check

The table GET miss with a function `__index` is at parity with stock in the
interpreter on both arches (looped kernels on the real input:
`frequency(seq,1)` 0.907 vs 0.963 ms/rep on arm; `-jp=fl` identical). The
`kfrequency` loop trace IR is byte-for-byte identical. What differed:

- `io.lines()`: the 5.4 port reads lines byte-wise (embedded NULs), with a
  locked getc(); 3.0-4.5 ms per MB against stock's fgets() 1.5-2.4 ms. An
  unlocked loop is no faster; POSIX `getline()` is (1.53-1.55 ms, parity).
  `c62fa218`. ~0.5 ms of the x64 run.
- x64 `checkint` macro: tag check plus a second mask/branch stage for the
  widened 47-bit encoding on every interpreter int path. A one-compare form
  gains 12% on pure int loops but loses 20-25% on the string.sub/TGETV paths
  (interleaved A/B, three rounds, each direction consistent): reverted. The
  -joff phase cost is ~8% per phase, within the deltas above.
- Whole-process x64 timing still shows a constant ~11 ms over stock that the
  in-script phase timings (startup 1.29 vs 1.32 ms, readlines, f1..K18 at
  parity with -jon) do not contain; it is after the script (lua_close /
  teardown) or in output. Measured next with os.exit(0,false) vs normal exit
  and strace -c (job queued at the time of writing; see Session 54 numbers).
- arm k-nucleotide: the box is bimodal (both binaries 1.6x slower in some
  runs); phase timings are at parity in the fast mode. The Session 53 "1.27"
  row and a 29 vs 17 ms run seen here are both that noise.

Also found, not this item: the parser folds `2147483647 + 1` to the float
2147483648.0 (PUC and our runtime add give the integer).
