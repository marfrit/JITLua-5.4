# JITLua-5.4 — master execution plan

Companion to `MISSION.md`. Tracks every phase with its gate and status.
Updated 2026-11-21 for the 1.0.0 release; the measured counts are in
[README.md](../README.md), the remaining differences in
[DIFFERENCES.md](DIFFERENCES.md), the fixed ones in
[CHANGELOG-VM.md](CHANGELOG-VM.md). The session log of the early phases is
[phase0-status.md](phase0-status.md).

Legend: `[x]` done · `[~]` done with a stated exception · `[ ]` open.

## Status snapshot, 2026-11-21

Release: **1.0.0** (tarball `JITLua-5.4-1.0.0.tar.gz`; the name `5.4.0` of
MISSION section 9 was replaced, see the decision in MISSION.md).
Platforms: Linux x86_64 (GC64) and Linux arm64.

Verification, identical on both architectures (README.md has the full list):

- `tests/d54` differential gates against PUC Lua 5.4.9: A+B 342 PASS / 0 FAIL
  / 4 XFAIL; JIT optimization levels 0–3: 732; dump/reload round-trip (R):
  175; assertion build: 183; GC stress: 187; ASan/UBSan A+B+R: 517 PASS /
  0 FAIL / 4 XFAIL; C API checks 258 + 92 + 18 and the `udfinal` probe.
- Full corpus (PUC 5.4.9 test suite plus `tests/d54`) with `--strict`, the
  public CI command: 592 PASS / 0 FAIL / 16 XFAIL / 3 SKIP / 0 TIMEOUT
  (217 tests, 608 jobs). Every XFAIL is a row in
  `tests/known-different.tsv` and in DIFFERENCES.md.
- `tests/known-bad.tsv`: no open defect.
- Classic benchmarks against stock LuaJIT 2.1 (`docs/perf-report-1.0.0.md`):
  within 10 % on both architectures except two readings of workloads that run
  for 10 ms or less, neither confirmed by a second measurement: x86_64
  `fasta` 0.84 in the 2026-11-21 run (1.039 in the interleaved run of
  2026-11-20; open work, item 7 below) and arm64 `nbody` 0.731 in the
  2026-11-20 run (0.982 measured alone on that host).

## Deviation from MISSION, 2026-11-21

MISSION phase 6 asks for 30 consecutive green days of coverage-guided fuzzing
before release. For 1.0.0 fuzzing is **not a release gate**. The fuzzers
(`tests/fuzz`, `tests/soak`) run in the local CI and found no open failure,
but the 30-day campaign has not been run. It continues after the release and
feeds 1.0.x. The decision and its reasoning are recorded in MISSION.md.

## Phases

| Phase | Gate (MISSION) | State |
|---|---|---|
| 0 — verification harness | harness runs, ASan clean | `[x]` harness (modes A, B, R), fuzzers, sanitizer builds, CI scripts |
| 1 — lexer, parser, bytecode, interpreter | mode A green | `[x]` int64 value model (ADR-001, ADR-001b), 5.4 grammar, numeric semantics, `<close>`, C API surface |
| 2 — IR int domain | mode B green for numeric, bits, metamethods | `[x]` |
| 3 — optimizer and backends | harness green at opt levels 0–3, all backends | `[~]` x86_64 and arm64 only; the 10M-program fuzz count of the gate is not part of 1.0.0 |
| 4 — GC and strings | GC stress green, ASan clean | `[~]` weak tables, `__gc`, 5.4 `collectgarbage` interface; one incremental collector, no real generational collector (`docs/gc-newgen-plan.md` Stage 3) |
| 5 — standard libraries | PUC suite green in mode A, mode B green | `[x]` all PUC suite files run except `all`, `api`, `code` (they need the suite's internal test library) and `heavy.lua`, which is left out of the default and `--strict` corpus and runs on request (`--include-heavy`, tests/README.md); FFI re-validated |
| 6 — hardening and release | zero open failures, 30-day fuzz, perf report | `[~]` perf report and docs done; fuzz campaign moves to 1.0.x |

Release documents: `docs/LUA54.md` (overview), `docs/DIFFERENCES.md`,
`docs/CHANGELOG-VM.md`, `docs/perf-report-1.0.0.md`,
`docs/RELEASE-NOTES-1.0.0.md`.

## Remaining for 1.0.x

1. **Fuzzing campaign.** Coverage-guided fuzzing of the interpreter and the
   JIT, differential in both directions, continuing after the release;
   failing seeds go into the corpus (MISSION section 7.3). Defects found are
   fixed in 1.0.x releases.
2. **Dead-slot liveness from snapshots.** A compiled loop keeps dead stack
   slots alive until the trace exits (the `gc.lua` GC1/GC2 loops at
   `-O0`..`-O2`). A bytecode scan per GC step was tried and removed because it
   mistook an inner `break` for the loop's back edge. Not tried yet: a bound
   from the snapshot use-def analysis (`lj_snap.c` `snap_usedef`), which the
   JIT already uses for its exits (DIFFERENCES.md, the row on eliminated
   allocations).
3. **Huge numeric-for limits (done for 1.0.0).** `for i = 1, math.huge`,
   `for i = 1, 1e10` and `for i = 1, math.maxinteger` run on the int32 path
   while the index fits and are compiled (`docs/notes/for-loop-54.md`, step
   4c): as a loop trace of their own, and as an inner loop that a trace
   around an enclosing loop enters (the recorded FORI calls a helper once per
   loop start). Not compiled: a loop whose index really crosses 2^31
   continues in the interpreter; a FORI whose limit is a numeric string, or
   whose start lies beyond the clip value, ends the trace. Open: short nested
   inner loops with an int32 limit measured 2-8 % slower on x86_64 after step
   4c.
4. **Latent 16-bit shift in `src/jit/bcsave.lua`.** `f16(x)` is
   `bswap(x) >> 16` (two copies, lines 254 and 386 at this commit), a 16-bit
   shift of a byte-swapped value that was written for LuaJIT's 32-bit bit
   operations. It is noted at release review as latent: no failing test
   exists. Before the file is touched, write a test that saves and reloads
   an object through `jit.bcsave` for a target of the other endianness, and
   decide from that result.
5. **Remaining difference rows.** Each `IMPL-DEFINED`/`FORK` row of
   DIFFERENCES.md that rests on "cannot be matched" is subject to the
   AGENTS.md rule that a negative never tried is not verified; rows get
   re-examined as time allows. A real generational collector is Stage 3 of
   `docs/gc-newgen-plan.md`.
6. **Other backends.** x86 (GC32 VM) lacks `BC_IDIV`, `BC_KI64`, `BC_TBC` and
   `BC_TBCCLO`; the interpreter port is tracked in
   `docs/notes/nogc64-2026-11-19.md`. arm, ppc and mips are not ported.
7. **Re-measure the 10 ms benchmarks.** x86_64 `fasta` read 0.84 against stock
   in the 2026-11-21 run (`docs/perf-report-1.0.0.md`); a ten-millisecond
   workload measured three times while other jobs ran is within noise.
   Repeat it with the interleaved runner (median of 9).

---

## ADR-001 — value model (the critical architectural decision)

**Status: superseded by ADR-001b** (`docs/adr-001b-boxed-i64.md`), which is
what the tree implements. `TValue` stays 8 bytes: an integer in int32 range
is stored inline as before, an integer of up to 47 bits inline under its own
tag on GC64, any other integer as an interned, boxed int64 (`UDTYPE_I64BOX`,
`lj_i64.c`); the IR has `IRT_I64`. There is no `LJ_TVSZ`, no `LJ_TISNUM64`
and no 16-byte slot anywhere in `src/`. The text below is the plan of
2026-11 as it was written, kept as the record of the decision; its "chosen"
design (ADR-001a) was not built.

**Finding (verified in-tree):** LuaJIT 2.1's dual-number mode stores integers as
**`int32_t`** (`lj_obj.h`: `TValue.i`, `intV`, `setintV`; `setint64V` demotes to
int32 or double). `TValue` is **8 bytes** with NaN-boxed tags:

* `LJ_GC64` (x64/arm64 default): 47-bit payload + 17-bit tag in one u64.
* non-GC64: 32-bit value + 32-bit tag.

**There is no room for a 64-bit integer plus a tag in 8 bytes.** MISSION §5's
"keep the JIT's existing register model" is fine for the *IR* (values live in
registers), but the *interpreter* cannot represent Lua 5.4 integers exactly
without a wider value slot. This is the single biggest structural change of the
port and the root dependency for Phases 1–3.

Options considered:

| option | exact int64 | invasiveness | verdict |
|---|---|---|---|
| keep 8-byte TValue, ints ≤2^53 only | no | none | rejected: breaks 5.4 |
| box large ints in a GC object | yes | high (value semantics everywhere) | rejected then; implemented as ADR-001b |
| split value/tag arrays (PUC-style) | yes | very high (rewrites all type dispatch) | rejected |
| **16-byte TValue: NaN-boxed low word + int64 in high word, new tag `LJ_TISNUM64`** | yes | high but mechanical | **chosen** then; superseded, not built |
| 16-byte TValue, PUC-style split tag | yes | very high | fallback only |

**Design chosen at the time (ADR-001a, not built):**
* `TValue` becomes 16 bytes (`LJ_TVSZ 16`, `LJ_TVSH 4`). Low 8 bytes keep today's
  NaN-boxed encoding for *all* existing types (nil/bool/str/func/tab/…/double).
* New internal tag `LJ_TISNUM64` in the low word; the full `int64_t` lives in the
  high word (`o->i64`). `tvisint()`/`intV()`/`setintV()` move to it.
* `LJ_DUALNUM` is forced on for all targets (5.4 requires the int/float split).
* Stack slots double: every `BASE+R*8` → `BASE+R*16` (x64/x86),
  `BASE, R, lsl #3` → `lsl #4` (arm/arm64), PPC equivalents. Register-save areas
  and other `*8` uses must NOT change — this is the main risk.
* C side mostly uses `sizeof(TValue)` already (22 sites) plus `tvref` arithmetic.
* Snapshots (`lj_snap.c`) restore TValues → must write 16 bytes and the int64 tag.
* IR: add `IRT_I64` as a first-class type (MISSION's `IRT_INT64`), keep `IRT_NUM`.

**Migration order (keeps the tree buildable):**
1. `LJ_TVSZ`/`LJ_TVSH` constants + `TValue` union + accessors (C only, compiles).
2. C users of hardcoded slot sizes (`lj_state.c`, `lj_func.c`, `lj_tab.c`, …).
3. VM assembly per backend, **arm64 first** (native, testable here), then x64
   (primary CI), then x86/arm/ppc/mips.
4. Snapshot/restore + JIT stack layout.
5. Only then: 5.4 arithmetic semantics (P1.4) and IR int64 (P2).

Until step 3 lands for an arch, that arch cannot run the 5.4 interpreter; the
harness is run on arm64 (native) and x64 (CI).

---

---

## Phase record (as planned in 2026-11)

The task lists of phases 0–6 that stood here are complete as listed in the
table above; their per-task history is in `docs/phase0-status.md` and in the
commit log (messages `Phase N (Mx): <task>`). The text of MISSION section 6 is
unchanged.

## Working agreements
* Tests before code (MISSION §7.2); every §4 box maps to a test in `docs/54port.md`.
* Keep the tree buildable and the harness green at every commit; use
  `tests/known-bad.tsv` to record expected failures, never to hide regressions.
* Long runs: background + poll, or `timeout N`. Never two harness runs at once.
* Commit messages: subject = content.
* Deviations from MISSION are recorded in `MISSION.md` (dated decisions), in
  `docs/phase0-status.md` (errata) and here (ADRs), never silently.
