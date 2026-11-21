# AGENTS.md — JITLua-5.4

Read by OpenCode and Pi. Claude Code reads `CLAUDE.md`, which carries the
same mandate. All three are bound by everything below.

`CLAUDE.md` is the project's rules (scope, publishing, measurement
discipline, commits, model selection); read it too. This file adds the
reading mandate on top of it, and it is not optional. Operator-local detail
(where to build and test, how to report) is in `CLAUDE.local.md` when that
file is present; read it before the first build or test run.

The goal is fixed in [MISSION.md](MISSION.md): **100 % source compatibility
with PUC Lua 5.4.9 wherever it is technically possible.** "Implementation-
defined" is a disposition only for what cannot match, and it always names the
technical reason.

---

## THE RTFM MANDATE — before the first substantive tool call of a turn

Any turn that touches a semantic decision, a VM or JIT mechanism, a library
function, the GC, or an entry in the difference lists STARTS by reading the
repository's own record and the reference implementation. Not after the
measurement. Not after the implementation. First.

**1. Read the record of the area.** `docs/DIFFERENCES.md` (every remaining
difference, with its class), `docs/CHANGELOG-VM.md` (every fixed one, with the
technical notes), the design notes under `docs/notes/` and the ADRs in
`docs/`. If a note covers the work, read it before touching code.

**2. Read the lists that gate the harness.** `tests/known-bad.tsv` (real
defects), `tests/known-different.tsv` (documented differences, per mode) and
`tests/t-guarded.tsv` (which PUC suite files run). A row there is a claim
somebody made; see rule 5.

**3. Read PUC's SOURCE, not only the manual.** The PUC 5.4.9 source is
vendored as a tarball under `tests/ref/dist/` and is built by
`tests/ref/fetch-ref.sh`. The manual describes intent; `lvm.c`, `ldo.c`,
`lgc.c`, `ldebug.c`, `lapi.c` and the library files are what a program
observes. Where manual and code disagree, PUC's code is the reference
behaviour. Cite `file:function` for PUC and for this tree.

**4. State the EVIDENCE CLASS of every disposition you write** — `manual`,
`puc-code`, or `measured-here` (which binary, which arch, which mode, which
opt level). A row without one is not a disposition.

**5. A label is not evidence.** `IMPL-DEFINED`, `FORK`, `EXTENSION`,
`PENDING` in an existing document record what someone concluded *from the
evidence they had*. Before you build on one, check what that evidence was.
An `IMPL-DEFINED` row whose reason is not "technically impossible, because
…" is a defect in the list.

**6. A negative that was never tried is not verified.** "Cannot match",
"would need a rework", "not reachable", "no program depends on it" are claims
that require an attempt or a measurement.

**7. The interpreter is not the whole VM.** Every semantic change has a
second implementation: the trace recorder (`lj_record.c`, `lj_ffrecord.c`)
and the compiled code of both backends (`vm_x64.dasc`, `vm_arm64.dasc`). A
check made while recording that the trace does not guard is a check that is
missing. Test the shape where a loop is compiled for one kind of value and
then meets another (mode B at opt levels 0–3).

**8. Context use is never a reason to drop work.** Compaction does not end a
session; write breadcrumbs (goal, open steps, decisions, file paths) and
continue. Shrinking, deferring or re-labelling part of the task because the
context is filling up is not a disposition.

---

## Why this file exists

One day of the 1.0.0 preparation, every item below on the record in this
repository's history:

- **A label stood in for an attempt.** Several PUC differences were proposed
  as `PENDING` or `IMPL-DEFINED` ("needs an unwinder rework", "an assembly
  change in both backends") while the session's context was filling up. Each
  of them — the return hook of `coroutine.yield`, yieldable `__close`
  handlers on the error path with PUC's debug levels, operand names through
  `_ENV` — was implemented the same day once someone tried. Rules 5, 6, 8.
- **A design rested on an unread source.** A proposal to move pending
  `<close>` values above the stack top argued that PUC does the same. It does
  not (`lfunc.c` closes from the highest slot down and sets the top above each
  one), and this tree's `gc_traverse_thread` sets every slot above the top to
  nil in the atomic phase: the next full collection would have erased a
  pending value and lost its handler. Reading two functions caught it before
  it was written. Rule 3.
- **A fix passed every gate and was wrong.** A GC parity change disabled
  allocation sinking for table constructors. All differential gates stayed
  green; compiled loops that sink their allocations became 70 to 380 times
  slower. Only the benchmark caught it. `CLAUDE.md`, measurement discipline.
- **A recorder check without a guard.** The table library learned to honour
  `__index`/`__newindex`/`__len`; its recorder looked at the metatable when
  recording and emitted no guard, so a loop compiled for plain tables kept the
  raw path when the metatable gained `__len` later. The interpreter tests were
  green. Rule 7.
- **A green branch, a red combination.** `collectgarbage("step", n)` ignored
  `n`; nothing noticed until another branch let `gc.lua` run past the loop
  that used to stop it. Gate the merged tree, not only the branches.

Reading the record costs minutes. Not reading it costs days and, in a JIT,
silently wrong code.

**RTFM first. Every turn.**
