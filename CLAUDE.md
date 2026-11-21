# JITLua-5.4 — session rules

Source of truth: [MISSION.md](MISSION.md) (goal and phases), README.md
(current measured state), `docs/DIFFERENCES.md` (every remaining difference
from PUC Lua 5.4.9, classed), `docs/CHANGELOG-VM.md` (every fixed one).
Operator-local detail (which machines build and test, how to reach them) is in
`CLAUDE.local.md`, which is git-ignored and read alongside this file.

## RTFM MANDATE — first, every turn

`AGENTS.md` carries this mandate in full and binds OpenCode and Pi; it binds
Claude Code identically. Before the first substantive tool call of any turn
that touches semantics, a VM/JIT mechanism, a library function, the GC or a
difference-list entry:

1. Read the record: `docs/DIFFERENCES.md`, `docs/CHANGELOG-VM.md`, the design
   note under `docs/notes/` that covers the work.
2. Read the harness lists: `tests/known-bad.tsv`, `tests/known-different.tsv`,
   `tests/t-guarded.tsv`.
3. Read PUC's source (vendored under `tests/ref/dist/`), not only the manual.
   Where they disagree, PUC's code is the reference behaviour. Cite
   `file:function` on both sides.
4. State the EVIDENCE CLASS of every disposition — `manual`, `puc-code` or
   `measured-here`.
5. A label (`IMPL-DEFINED`, `FORK`, `PENDING`) is not evidence; check what it
   rested on. `IMPL-DEFINED` means technically impossible, with the reason.
6. A negative that was never tried is not verified.
7. Every semantic change has a second implementation in the recorder and the
   compiled code of both backends; test it in mode B at opt levels 0–3.
8. Context use is never a reason to drop work; compaction does not end the
   session.

## The goal

100 % source compatibility with PUC Lua 5.4.9 wherever technically possible.
Every difference you find is its own row in your report and then either fixed
or documented in `docs/DIFFERENCES.md` with its class and reason. Never drop
one, never file one as "not my problem": if it belongs to another branch, it
still goes into the report.

## This repository is public

Every commit lands where anyone can read it:

- No host names, no addresses, no local paths, no credentials, no session
  links — not in code comments, not in docs, not in commit messages.
- Operator-local detail belongs in `CLAUDE.local.md` (git-ignored). Working
  notes are `docs/notes/WORKING-*.md`, also git-ignored; they are never
  committed. Finished design notes go under `docs/notes/` without that prefix.
- Uncommitted work is invisible; commit before anything is merged.

## Work order

- A red test first: a new case in `tests/d54/` that fails on the unchanged
  tree for the intended reason (modes A and B, B at opt levels 0–3). A test
  that was green before the change measures nothing. A loop that waits for the
  collector gets an iteration guard, never a timeout.
- Then the source, on both backends (x86_64 and arm64) where the VM is
  touched. A fix in an assembler fast path also needs its recorder side.
- Then the docs: the row leaves `docs/DIFFERENCES.md` / the TSV lists, the
  entry goes into `docs/CHANGELOG-VM.md`.
- Commits in that order (test, src, docs). Subject = content. The body says
  which model implemented it, with `Co-Authored-By` lines.
- Tiered gate, `tests/gate.sh --tier quick|touch|full` (details in
  `tests/README.md`): `quick` after edits, `touch --base HEAD` before each
  commit (one architecture, on a box), `full` on both architectures only before
  a review and before a push. `full` is the whole chain: `sh tests/ci-box.sh`,
  `sh tests/ci-local.sh --sanitizers-only`, and the strict CI command
  `tests/harness.sh --mode all --timeout 120 --strict`. Gate the merged tree,
  not only the branches.

## Measurement discipline

- A test must be able to fail. Run the red case first.
- Every change that touches the VM, the JIT or the GC gets a benchmark: one
  interleaved job per architecture, base against head, median of 7, with
  `-joff` and `-jon`. Nothing else may run on that machine during the
  measurement; a bimodal result is reported with its raw values, not as a
  median.
- Name the architecture, mode and opt level whenever a number moves.
- A claimed defect or explanation is accepted only with a measurement of its
  root cause. Report what happened, including what did not work.

## Model selection for agents / subagents

* Daily coding and implementation: Sonnet 5 for feature work, routine
  debugging, and most subagent execution.
* Complex architecture: Opus 5 for thorough code reviews, subtle bug detection
  and architectural trade-offs.
* Simple subagent tasks: Haiku 4.5 for bounded searches, summaries or
  mechanical file operations.
* Hardest agentic work: Fable 5 for code reviews before pushing.

## Language

Code and docs in English. Conversation follows the user.
