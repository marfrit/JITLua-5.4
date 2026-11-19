# resume-chain crash (branch `fixresume`, 2026-11-19)

## Summary

A chain of nested `coroutine.resume` calls **SIGSEGVs on x86_64** once the 5.4
C-call bound is reached (~201 levels). PUC 5.4.9 raises a clean
`C stack overflow` at 198. aarch64 does not crash but reaches three levels
deeper than PUC. The crash comes from the `453787f2` resume fast path: it
falls back to the C handler (`->fff_fallback` -> `ffh_resume` ->
`lj_vm_resume`) at the deepest point of the chain, and that C path cannot
nest as deep as the inline fast path. The fix is **not finished**; the
evidence and the open leads are below.

## Consolidation decision (this round)

The resume-nesting inheritance does **not** ship. The resume-inheritance part of
`453787f2` (the x64/arm64 `coroutine_resume`/`coroutine_wrap_aux` fast-path
code, the `ffh_resume` bound and the `lua_resume` `from` inheritance) was
reverted on branch `fixresume` (commit `d7e31723`); the close-time finalizer
part of the same commit (`GCState.closing`) and `f3eb7ec0` (closethread /
`coroutine.close` inherit the closer's nesting) are kept.

* Regression guard: `tests/d54/err_07_resume_chain.lua` runs depths 1..300 and
  asserts every depth returns ("bottom" or a caught error) and prints nothing
  depth-specific, so PUC (which stops at 198) and this fork (which runs the
  chain to completion) produce the same output. It SIGSEGVs on the
  pre-revert tree, so it catches a re-introduction without the fix.
* `tests/d54/err_06_coro_ccallnest.lua` is back to failing in mode A and is
  listed in `tests/known-bad.tsv` (mode `A`) with this reason.
* `docs/notes/resume-chain-crash.lua` is the standalone repro script.

## Can the kept closethread change crash the same way? No

A chain of `coroutine.close` calls from `__close` handlers (each level closes a
suspended coroutine whose `__close` builds and closes the next one) was run to
depth 300 on x86_64 and aarch64, `-joff` and `-jon`: no crash, no error, the
chain completes (depth `d` reaches `d+1` levels). PUC 5.4.9 stops the same
chain at 198 with a clean "C stack overflow", so the kept change diverges in
that it only *counts* the closer's nesting without enforcing the bound on this
path. That divergence is open (see below); it is not a crash.

## Red evidence (fresh `git archive integ7` = d28858b7)

x86_64 (x64-box), `-joff` and `-jon` identical:

| | d=196 | d=197 | d=198 | d=199 | d=200 | d=201 | d=202 | d=250 |
|---|---|---|---|---|---|---|---|---|
| PUC 5.4.9 | bottom | bottom | err@1 | err@2 | err@3 | err@4 | err@5 | err@53 |
| ours | bottom | bottom | bottom | bottom | bottom | **SIGSEGV** (rc=139) | | |

aarch64 (arm-box), `-joff` and `-jon` identical: no crash, but
`d=196..200 bottom`, `d=201 err@1`, `d=202 err@2`, `d=250 err@50` — the bound
is reached three levels later than PUC.

## Mechanism

Established with gdb and with single-variable builds of the x64 fast path:

1. **The crash needs the `ccallnest` increment to take effect.** Every
   variant whose increment is a no-op survives (the bound then never fires):
   check+branch removed, load only, constant store, check+branch only, and
   `add aword <mem>, imm` (which dynasm silently assembles to nothing — see
   the trap below).
2. **The crash happens when the fast path takes `->fff_fallback`.** With the
   bound check forced to always branch (so the C path runs for every resume),
   the chain still dies at d=201. integ7 *without* the fast-path block (C-side
   inheritance only, fast path untouched) survives to d=300.
3. **It is not the process C stack.** `ulimit -s 65536` does not change the
   crash depth. The faulting `rsp` is near the top of the stack.
4. **gdb at the fault:** `and 0xc(%rax),%r10d` with `rax = 0xb` — a corrupt
   pointer, not a stack-guard hit; ~200 identical VM frames
   (`0x...9065f`), then `lua_pcall`, then `main`.
5. The inserted block also sat **after** `mov L:RB->top, PC`, unlike every
   other fallback jump in that handler (all before the state mutation). That
   is a real hazard on its own.

## Measured effect of the requested fix

PUC's formula is `nCcalls = from + 1; error if >= LUAI_MAXCCALLS`. Applying it
to the fast paths, `ffh_resume` and `lua_resume`, and moving the check before
`mov L:RB->top, PC`, moves the crash from d=201 to d=200 — **it still
crashes**. Adding PUC's main-thread baseline (`LJ_CCALLNEST_BASE 2`) moves it
to d=198 — still crashes. So matching PUC's reachable depth alone does not
avoid the crash: the C fallback path is already unusable at ~197.

## Open (next round)

1. **Raise the bound error without the generic C fallback** (the route chosen
   by the consolidation). A dedicated VM helper in the style of the `->vm_*`
   entries that sets the coroutine's error and returns would avoid
   `ffh_resume`/`lj_vm_resume` frames at depth and should remove the crash;
   then the resume inheritance can be re-applied. This is the most promising
   route.
2. Or find out why the C fallback path consumes so much more C stack per level
   than the inline fast path (LuaJIT switches to the coroutine's own stack
   region in `lj_vm_resume`) and reduce it.
3. Move the check before `mov L:RB->top, PC` in `vm_x64.dasc` regardless — it
   is a real hazard independent of the crash.
4. Enforce the bound on the kept closethread path, where PUC errors at 198 and
   this fork currently runs on (no crash, see above).
5. aarch64 reaches 3 levels deeper than PUC (no crash). The same baseline
   question applies: PUC's `nCcalls` includes the embedding's C frames, while
   `ccallnest` is 0-based, so a fixed baseline only approximates it.
6. Keep `LJ_MAX_XLEVEL`/`LJ_CCALLNEST_BASE` consistent across the interpreter,
   the trace counter (`lj_record_ccallnest`), the C API and both arches.

## Trap for the next attempt

`add aword <mem>, <imm>` in dynasm silently produces no increment (the count
stays 0 and the bound never fires, which *looks* like a fix). Use
`mov <reg>, ...` / `mov <mem>, <reg>` as the existing pcall fast paths do.
