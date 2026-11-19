# k-nucleotide — per-cycle phase-alignment census and the policy question

Measurement only, branch `knuc`. No default was changed. The instrument is the
`LUAJIT_GC_STATS` build's per-cycle counter, extended here with a `clock()` /
`CLOCKS_PER_SEC` timestamp and the per-cycle mark / sweepstring / sweep /
atomic split; a copy of k-nucleotide prints stage boundaries on stderr with
`os.clock()`, which reads the same clock, so each completed cycle can be
attributed to the workload stage it landed in. Everything stays behind the
existing stats define (`LUAJIT_GC_CENSUS` adds the full live-object census).

Companion to `docs/notes/knuc-perf-2026-11.md`, which established that the gap is a
collector-policy effect (the `setpause` sweep flips its sign) and not a slow
walk. This document names the mechanism and answers whether a policy change
would remove the gap without hurting binary-trees, lpeg and lua-cjson.

## The mechanism, in one paragraph

The non-monotonic curve is the collector's cycle spacing deciding *which
workload stage carries the retained heap*. On x64, at the default
`setpause=200` ours completes 8 cycles, three of them inside `k12` and one
inside `k18`, and the `k18` stage — the one that builds the ~50 000-key table —
runs from 24 532 to 50 997 live strings with a 65 536-chain string table, for
26.5 ms of mutator CPU; at `setpause=150` it completes 13 cycles (five in
`k12`, two in `k18`) and `k18` runs from 16 850 to 34 746 strings for 17.2 ms,
while the collector's own CPU rises from 7.6 ms to 20.7 ms. The two move in
opposite directions and nearly cancel: the sum of the stage CPU times is 65.3,
65.7 and 65.0 ms at `setpause` 200, 150 and 300. Stock shows the same trade but
its optimum sits at the default, so its default is the good point and ours is
not. The reproducible wall difference that is left — 0.89 → 1.00 on x64 and
0.853 → 0.979 on arm, median of 5 / 11 interleaved runs — is therefore on the
mutator side, i.e. the cost of carrying the uncollected heap, not the
collector's own work.

### Census, x86_64 test host (stats build, CPU microseconds)

| `setpause` | cycles | collector total | k12 dur (gc/mut) | k18 dur (gc/mut) | k18 live strings | k18 heap |
|---:|---:|---:|---:|---:|---:|---:|
| 150 | 13 | 20 714 | 21 000 (5 924 / 15 071) | 31 130 (13 972 / 17 160) | 16 850 → 34 746 | 2.1 → 3.6 MB |
| 200 (default) | 8 | 7 593 | 21 440 (3 027 / 18 409) | 30 500 (3 955 / 26 543) | 24 532 → 50 997 | 2.1 → 4.2 MB |
| 300 | 6 | 12 987 | 22 160 (3 231 / 18 926) | 28 820 (9 477 / 19 339) | 26 347 → 29 867 | 2.2 → 2.7 MB |

Per-cycle detail (x64, `setpause=200`) — the cycle number, the stage it landed
in, and its phase split in microseconds:

| # | stage | total_kb | str_num | cyc_us | mark | sweepstr | sweep | atomic |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | boot | 65.3 | 400 | 90 | 23 | 60 | 5 | 2 |
| 2 | boot | 115.8 | 830 | 138 | 23 | 72 | 40 | 3 |
| 3 | freq1 | 141.4 | 329 | 141 | 18 | 104 | 17 | 2 |
| 4 | k6 | 320.6 | 2 378 | 223 | 45 | 138 | 26 | 14 |
| 5 | k12 | 539.3 | 4 451 | 635 | 55 | 537 | 22 | 21 |
| 6 | k12 | 958.7 | 8 737 | 631 | 113 | 442 | 20 | 56 |
| 7 | k12 | 2 085.7 | 24 532 | 1 406 | 221 | 1 036 | 23 | 126 |
| 8 | k18 | 4 196.6 | 50 997 | 3 727 | 512 | 2 851 | 33 | 331 |

Every cycle is dominated by the string sweep (57–80 % of its time) and the
cycles grow with the heap: cycle 8 costs 3.7 ms against cycle 5's 0.6 ms. The
last cycle is the one that lands in `k18` at the default.

### Census, arm64 test host (same instrument)

| `setpause` | cycles | collector total | k12 dur (gc/mut) | k18 dur (gc/mut) |
|---:|---:|---:|---:|---:|
| 150 | 13 | 8 706 | 10 280 (2 744 / 7 538) | 13 070 (5 574 / 7 501) |
| 200 (default) | 8 | 2 108 | 9 150 (860 / 8 294) | 11 580 (1 092 / 10 489) |
| 300 | 6 | 5 305 | 8 670 (1 327 / 7 343) | 11 760 (3 848 / 7 912) |

The same shape: the collector does least at 200 (2.1 ms) and the `k18` mutator
costs most there (10.5 ms against 7.5 / 7.9).

## Would a policy change remove the gap?

Two knobs were measured, median of 5 (x64) and 11 (arm) interleaved runs in
one job on one box, ours vs stock, `-jon`. Ratios are `stock/ours` where stock
ran (k-nucleotide, binary-trees) and `ours-default/ours-setting` where it did
not (lpeg, lua-cjson — see the note below); in both cases **1.00 is parity**
and lower is slower.

| setting | k-nucleotide x64 | k-nucleotide arm | binary-trees x64 | binary-trees arm | lpeg x64 | lua-cjson x64 |
|---|---:|---:|---:|---:|---:|---:|
| stock | 1.00 | 1.00 | 1.00 | 1.00 | (n/a) | (n/a) |
| ours, default | **0.89** | **0.853** | 0.97 | 1.00 | 1.00 | 1.00 |
| `setpause=150` | 0.91 | 0.920 | 0.84 | 0.90 | 0.96 | 0.90 |
| **`setpause=300`** | **1.00** | **0.979** | **1.07** | **1.04** | **1.00** | **1.00** |
| `setpause=500` | — | 0.954 | — | 1.09 | — | — |
| `setstepmul=400` | 0.92 | 0.899 | 0.95 | 0.98 | 1.01 | 0.98 |
| `setpause=300;setstepmul=100` | 0.94 | 0.932 | 1.11 | 1.07 | 0.98 | 1.02 |

Absolute medians, x64: k-nucleotide stock 68.3 / ours default 76.8 /
`setpause=300` 68.4 ms; binary-trees stock 926.6 / default 958.9 / 300 862.0 ms;
lpeg stock n/a (see note) / default 462.3 / 300 460.9 ms; lua-cjson default
415.4 / 300 415.2 ms. Arm: k-nucleotide stock 17.38 / default 20.36 / 300
17.75 ms; binary-trees stock 177.33 / default 176.72 / 300 169.89 ms.

* **`setpause=300` removes the k-nucleotide gap on both arches** (x64 0.89 →
  1.00, arm 0.853 → 0.979) and *improves* binary-trees on both (x64 0.97 →
  1.07, arm 1.00 → 1.04). lpeg and lua-cjson are unchanged against their own
  default (lpeg 462.3 → 460.9 ms, −0.3 %; lua-cjson 415.4 → 415.2 ms, −0.05 %).
* **Step granularity alone does not.** `setstepmul=400` leaves k-nucleotide at
  0.92 / 0.899; it is the pause, not the step size, that carries the effect.
* **It is paid for in peak RSS**, from the same grid's `ru_maxrss`: binary-trees
  33.0 → 43.2 MB (+31 %), lpeg 16.7 → 19.6 MB (+17 %), lua-cjson 126.8 →
  127.1 MB (unchanged). `setpause=150` goes the other way on both axes
  (binary-trees 33.0 → 25.2 MB, lpeg 16.7 → 16.2 MB) and is worse in time.
* `setpause=500` buys more on binary-trees (1.09 arm) and less on k-nucleotide
  (0.954), i.e. the two workloads do not share one optimum.

Note on the corpus rows: the stock arm cannot load a module built against the
fork's headers, so the lpeg / lua-cjson columns are ours-relative (default =
1.00) rather than stock-relative; the stock comparison for those two comes
from the gcbase baseline (stock lpeg 384.5 ms, lua-cjson 428.5 ms). Their
absolute x64 medians here are lpeg 462.3 ms at the default and 460.9 ms at 300,
lua-cjson 415.4 and 415.2 ms.

## What this says

A pause change **would** remove the k-nucleotide gap without hurting lpeg or
lua-cjson, and it would help binary-trees; `setpause=200 → 300` is the setting
that does it, on both arches. It is not free: it trades peak RSS for time, most
visibly on binary-trees (+31 %), and it moves every workload that allocates, so
it is an operator decision and is not applied here. Two things would still be
needed before such a change is made:

1. **The corpus and the rest of the classic set at 300**, on a quiet box with
   enough repetitions — the arm box's variance at the default repetition count
   was ±20 % on binary-trees, which is why the arm grid here uses 11 reps.
2. **A decision rule for the trade.** The data supports "raise the pause when
   the workload keeps a large live set and allocates steadily" but does not
   test an adaptive rule; that needs the same instrument plus an
   allocation-rate input, which is a design change, not a constant.
