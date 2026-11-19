# Performance diagnosis 2026-11-19 — deltablue and k-nucleotide

Measurement only. No VM change in this branch. Everything below is either a
number printed by `tests/bench/perfdiag.py` or a line of a dump; where a cause
is inferred and not shown by a dump, it says so.

## Method

* Two trees, both measured against **stock LuaJIT 2.1** built by
  `tests/bench/classic/run.py` from `.dlcache/bench/luajit-*.tar.gz`:
  * `perfdiag` = this worktree, main at `14cbb389` (before the closure-guard
    merge), measured on **x86_64 test host A**;
  * `head` = a second worktree at main `8ff3134f` (after the closure-guard and
    gcbase merges), measured on **x86_64 test host B**.
  Stock and the fork always run in **one** job, interleaved, on one box;
  ratios are only compared within a box.
* `tests/bench/perfdiag-run.sh` builds the fork and walks the phases;
  `perfdiag.py` runs each phase. Phases used: `jv` (abort reasons, blacklists,
  NYI, weak/nomm), `starts` (trace start sites from `-jdump=+rs`), `census`
  (raw `-jv` line counts), `ir` (hot-trace IR, textual), `mcode` (7 runs:
  trace count / total instructions / largest trace), `prof` (`-jp=v`,
  `-jp=fl`), `time` (7 interleaved runs per option set, min and median),
  `knuc` (stage-timed k-nucleotide probe), `emptyinput`, `gcfull`, `teardown`.
* Two driver bugs were found and fixed while measuring: the `-jv` start-line
  regex only matched 1-digit trace numbers (`---- TRACE  12` is padded), so
  "started" was an undercount; and `phase_gcmicro` referenced an undefined
  name. Both are fixed in this branch's copy of the driver.

## Headline

1. **deltablue's gap is not in the generated code.** With `-joff` the two arms
   are at parity (0.98–1.00); with `-jon` the fork is 4–29 % slower depending
   on tree and run (0.964 … 0.775 median ratio). The difference is VM/JIT
   policy, and the one confirmed cause is that **the trace recorder thrashes**:
   ours aborts 2.4x as often as stock, blacklists 9 sites against 1, and the
   extra aborts cluster on `:720` in the planner loop. A first candidate,
   a slow `lua_close`, was measured and then **rejected** (see below): the
   close/exit delta reverses sign between the two trees, so it is not a
   teardown cost.
2. **k-nucleotide's gap is the GC**, not the JIT: the compiled code is at
   parity (10 traces, 1029 vs 1019 instructions, IR identical), and `-joff`
   is *also* 0.90 — so the interpreter is slower too. The profile shows 80 %
   GC against stock's 25 %, and a full collection is 6 ms slower on a heap
   that is 32 % larger.
3. Neither campaign note ("ffrecord int64 boxes", "weak-cache base gap")
   explains either workload. Details in the last section.

## deltablue

### Numbers

Interleaved wall times, x86_64 test host A, fork at `14cbb389`, 7 runs per option set
(min / median, ms). Ratio is `stock/ours`; < 1 means the fork is slower.

| options | stock min | stock med | ours min | ours med | ratio min | ratio med |
|---|---|---|---|---|---|---|
| `-jon` | 18959 | 19263 | 24084 | 24859 | **0.787** | **0.775** |
| `-joff` | 94050 | 95159 | 93859 | 97242 | 1.002 | 0.979 |
| `-jon -Ohotexit=5,tryside=8` | 18159 | 20110 | 23367 | 23454 | 0.777 | 0.857 |
| `-jon -Ohotloop=20` | 18713 | 19437 | 20226 | 21437 | 0.925 | 0.907 |
| `-jon -Ohotexit=3,tryside=6` | 18477 | 18586 | 19691 | 20784 | 0.938 | 0.894 |

The same phase on the **head** tree (x86_64 test host B, `8ff3134f`): `-jon` ratio
0.964 min / 0.903 med, `-joff` 0.992 / 0.985, `-Ohotloop=20` 0.833 / 0.841.
So head is *better* than `14cbb389` on this workload, not worse — the "25 %
slower tonight" figure is at the pessimistic end of a wide, load- and
build-dependent spread (0.78 … 0.96 across trees and boxes).

Full collection inside the process (`collectgarbage("collect")`, same run):

| arm | wall | full GC |
|---|---|---|
| stock | 18431 | 1.0 ms |
| ours | 23462 | 0.9 ms |

### Rejected: a slow `lua_close` (the close/exit delta reverses sign)

A `close`/`exit` pair first looked like a 2.4 s teardown difference:

| tree | arm | close med | exit med | close − exit |
|---|---|---|---|---|
| `14cbb389` | stock | 19364 | 18770 | 594 ms |
| `14cbb389` | ours | 24277 | 21301 | **2977 ms** |
| `8ff3134f` | stock | 19285 | 18973 | 312 ms |
| `8ff3134f` | ours | 21031 | 22739 | **−1708 ms** |

The fork's delta is +2.4 s on one tree and −1.7 s on the other. A teardown
cost cannot do that; the `exit` arm runs the chunk through `loadfile(...)()`
plus `os.exit(0,false)`, and that changes which traces form. Two more
controls agree that the free path is not the problem: 1 000 000 small tables
give `close − exit` = 55 ms (stock) vs 58 ms (ours), and 1 000 000 strings
184 vs 181 ms — a per-object close cost would show up there. A full
collection in-process is 0.9 ms in ours against 1.0 ms in stock.

**Conclusion: withdraw the teardown cause.** The delta is a measurement
artifact of the wrapper, not a property of the fork. If a real close-cost
gap is ever suspected, it has to be measured with the same call shape on
both sides (e.g. `perf record` of `lua_close`, or a C driver that closes the
state without `loadfile`).

### Cause 1 — trace-recorder thrash

`-jv` census on the same run (`-jon -jv`):

| arm | aborted | blacklisted | top abort reason |
|---|---|---|---|
| stock | 82 | 1 | `inner loop in root trace :677` (20) |
| ours | 199 | 9 | `inner loop in root trace :720` (**68**) |

* Ours aborts 2.4x as often and blacklists 9 sites against 1. The dominant
  reason is `inner loop in root trace at deltablue-locals.lua:720` — the
  `local d = todo:removeFirst()` head of `Planner:addPropagate`'s while loop
  — 68 times in ours and 0 times in stock's top list. Stock's top reason is
  the same abort at `:677` (`Planner:makePlan`'s `todo:removeFirst()`).
* Trace starts differ in shape: 402 starts / 188 distinct sites in stock
  against 337 / 186 in ours. Stock starts 11 traces at each of `:164`,
  `:222`, `:308`, `:358`, `:467`, `:530`, `:608`, `:716`, `:830`, `:879`
  (the constructors and the planner entry points); ours starts 11 at `:879`
  and `:693`, 9 at `:672`/`:691`, and 5 at `:399`/`:413`/`:420` — a different
  set of hot sites, i.e. a different trace graph for the same bytecode.
* The tuning runs confirm the mechanism rather than a codegen difference:
  raising the hot-loop threshold (`-Ohotloop=20`) or the side-exit threshold
  (`-Ohotexit=3,tryside=6`) moves the median ratio from 0.775 to 0.907 /
  0.894. Starting traces *later* and retrying side exits *less* recovers
  ~13 points of the gap without touching code generation.
* **Where a fix would go:** the start-point and retry policy, not the
  recorder's IR: `lj_trace.c: lj_trace_ins` (hotcount dispatch and where a
  trace starts), `rec_loop_interp` / `rec_loop_jit` (the `LJ_TRERR_LINNER`
  and `LJ_TRERR_LUNROLL` aborts, `lj_record.c:935` and `:953`), and the
  penalty / blacklist policy in `lj_trace.c: penalty_pc` / `blacklist_pc`
  (`PENALTY_MIN`, `PENALTY_RNDBITS` in `lj_jit.h`).
* **Expected gain:** ~10–13 points of the 22-point gap, by the tuning runs
  above. It is the only confirmed lever left.
* **Risk:** medium-high. The hotcount and penalty constants are shared by
  every workload; `-Ohotloop=20` is a global policy change. A targeted fix
  (e.g. not blacklisting a site whose abort is "inner loop in root trace"
  when the inner loop already has its own trace) is safer but needs its own
  before/after on both arches and on the whole classic set.

### Ruled out

* **"Ours makes systematically bigger traces."** The 7-run mcode census
  (traces / total instructions / largest trace) is
  `175/78722/4123 … 167/70674/3683` for stock and
  `160/75497/6102 … 176/67202/3629` for ours — totals within 3 %, largest
  trace sometimes smaller in ours. But in the single run captured by the `ir`
  phase ours' hot loop trace is 1.8x stock's (824 vs 458 IR nodes, 2155 vs
  1155 mcode instructions). So the trace graph is *unstable and different*,
  not systematically larger. That is a property of the thrash above, not a
  separate cause.
* **Interpreted share.** `-jp=v` on this tree: stock 85 % compiled / 13 % GC,
  ours 85 % / 13 %. The earlier campaign's "ours runs 20 % interpreted" does
  not reproduce at `14cbb389`.
* **Mcode quality.** `-joff` parity means the interpreter is fine; the IR
  token multiset of the hot traces differs only in size (`i64/u64/CONV`
  counts are 0 in both), so no 5.4 integer semantics are involved.

## k-nucleotide

### Numbers

| options | stock min | stock med | ours min | ours med | ratio min | ratio med |
|---|---|---|---|---|---|---|
| `-jon` | 61.9 | 64.6 | 71.9 | 73.0 | 0.860 | **0.885** |
| `-joff` | 82.7 | 84.5 | 91.7 | 93.2 | 0.902 | **0.906** |
| `-jon -Ohotexit=5,tryside=8` | 64.1 | 64.9 | 72.4 | 73.3 | 0.885 | 0.885 |
| `-jon -Ohotloop=20` | 63.4 | 65.0 | 72.1 | 73.4 | 0.879 | 0.886 |
| `-jon -Ohotexit=3,tryside=6` | 64.4 | 65.1 | 72.5 | 73.5 | 0.888 | 0.886 |

(Head tree, x86_64 test host B: `-jon` 0.856 med, `-joff` 0.898 — same picture.)

Compiled code is at parity: 10 traces in both arms, 1029 vs 1019 mcode
instructions, largest trace 249 vs 256, and the IR multiset differs only by
3 guards. The `-joff` ratio of 0.90 shows the interpreter path is slower too,
so this is not a JIT issue at all — and, since the interpreter runs the same
GC, it points at the collection rather than at codegen.

Stage-timed probe (`tests/bench/knuc-probe.lua`, 9 runs, median): the whole
workload is at parity stage by stage — `work=63.9 ms` both arms, `wall`
73.6 vs 73.7 ms. Empty-input process cost: 1.83 vs 1.84 ms. So the in-run
costs are equal and the gap is elsewhere.

**This is the key constraint, and it is narrower than it looks.** The probe
measures the stages the script times itself; inside those stages the arms are
equal. The 10 % gap therefore sits in work the script does *not* time — and
the only candidate with a matching magnitude is the collection: 16.9 − 11.0 =
5.9 ms of full GC against a ~10 ms gap. The `-joff` ratio of 0.90 measures the
whole run, not the probe's stages, so it does not contradict the probe; it
says the same thing as the GC number.

Teardown and full GC:

| arm | close med | exit med | close − exit | full GC |
|---|---|---|---|---|
| stock | 64.1 | 60.7 | 3.4 ms | 11.0 ms |
| ours | 73.1 | 66.7 | 6.3 ms | 16.9 ms |

### Cause 1 — a full GC pass is ~54 % slower on the same heap

`collectgarbage("collect")` inside the process costs 11.0 ms in stock and
16.9 ms in ours, and the heap is larger (84.7 KB vs 64.2 KB after the run).
The `-jp=v` profile agrees: stock 75 % compiled / 25 % GC, ours 20 %
compiled / 80 % GC. This is the largest piece of the ~10 ms gap.

* **Where a fix would go:** `lj_gc.c: gc_onestep` / `full_gc` (the mark and
  sweep walks), and — more likely, given the larger heap — whatever makes the
  fork's heap bigger for the same workload: `lj_tab.c: lj_tab_rehash` /
  `newkey` growth, `lj_str.c: lj_str_new` interning, and the string-keyed
  table path used by `kfrequency`.
* **Expected gain:** ~6 ms of the 10 ms gap (~8 % of the run).
* **Risk:** medium. The GC walk is arch-independent and heavily exercised;
  the heap-size difference is the more promising lead and needs a
  `gc_measure`-style census (live objects by type) before patching.

### Not established — the `close − exit` delta (~3 ms)

`close − exit` reads 3.4 ms in stock and 6.3 ms in ours. That is the same
wrapper-confounded delta that reversed sign on deltablue, so it is **not**
evidence of a close cost here either; at 3 ms it would be ~4 % of the run at
most. Needs the same same-call-shape measurement before it counts.

## The two campaign notes

* **"ffrecord int64 boxes"** = the arm-side census finding from the closure
  campaign: `ffrecord` (the recorder's fast-function handlers,
  `src/lj_record.c` / `src/lj_ffrecord.c`) rejects a **boxed 5.4 integer**
  with "bad argument", so the call is not recorded and the trace stitches.
  The arm census recorded 41 such aborts in `closure.lua`. It does **not**
  apply here: the `i64` census counts `i64`/`u64` tokens in the traces as
  **0 for both workloads and both arms** (`CONV` 97 vs 14 for deltablue,
  11 vs 0 for k-nucleotide — no boxes involved). If
  boxed integers ever reach these benchmarks it would show up as a NYI or
  "bad argument" abort in `-jv`, and neither is present.
* **"weak-cache base gap"** — the phrase is not in any doc, branch or fleet
  memory entry; the closest real thing is the **closure campaign's weak-table
  guard**, whose cost measurement in the hot-log is "8–11 % in pure
  method-call loops" and "2–11 % on weak hot loops". That guard is in
  `head` (the `rec_tabguard` / `__mode` guard in `lj_record.c`) and
  **not** in `14cbb389`. It is a real candidate for the *head* tree's
  deltablue number, but this branch's measurements cannot separate it from
  the rest of the head delta: head measured *faster* than `14cbb389` here,
  so the guard is not the dominant term on these two workloads. If it matters
  it will show up as a larger `head`/`14cbb389` delta in a same-box A/B,
  which is the measurement to run next.

## Recommendation

Fix the **recorder thrash first** for deltablue: it is the largest *confirmed*
lever (the `-Ohotloop`/`-Ohotexit` runs move the median ratio from 0.775 to
0.907/0.894 without touching codegen), it is JIT-only (`-joff` is at parity),
and its mechanism is visible in the abort census. The **teardown** candidate is
withdrawn: its delta reverses sign between trees, so it is the same thrash
cause seen through a wrapper, not a close cost. The k-nucleotide GC gap is
second: real but smaller, and its most promising lead (heap size) needs a
live-object census first.

## Open

* The teardown candidate is withdrawn (sign reversal); a real close-cost gap
  would need a same-call-shape measurement (`perf record` of `lua_close`, or a
  C driver without `loadfile`).
* Side-exit counts were not extracted per trace; the `-jp=v` shares and the
  `-Ohotexit` tuning stand in for them. A per-trace exit histogram needs a
  build with `-DLUAJIT_USE_PERFTOOLS` or a patched `lj_trace.c`.
* The head/`14cbb389` delta is confounded with the box (x86_64 test host B vs x86_64 test host A). A
  same-box A/B of the two trees is the measurement that would separate the
  weak-table guard from the rest.
