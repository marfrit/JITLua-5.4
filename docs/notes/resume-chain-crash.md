# resume-chain crash (branch `fixresume`, 2026-11-19)

## Summary

A chain of nested `coroutine.resume` calls **SIGSEGVs on x86_64** once the 5.4
C-call bound is reached (~201 levels) when the resume fast paths inherit the
resumer's C-call count. PUC 5.4.9 raises a clean `C stack overflow` at 198.
aarch64 did not crash but reached three levels deeper than PUC.

The cause was **not** a C-stack limit of the `->fff_fallback` ->
`ffh_resume` -> `lj_vm_resume` route: that route does not call
`lj_vm_resume` at all, and the fallback handler nests fine at the bound.
The crash was a register hazard in the inserted x64 fast-path block: it
loaded the resumer state through **`KBASE` (r15)**, which is the *caller's
bytecode constants base*. `KBASE` survives a resume through the callee-save
restore at the end of `->vm_resume`, so the next string-key opcode in the
resumer read a GCstr pointer out of a `lua_State` and faulted in
`lj_BC_TGETS`. aarch64 used `TMP0`, which is why it did not crash.

The fix is applied on branch `resumenest`: the PUC formula
(`ccallnest = from + 1; error if from >= 200`) is used in the
`coroutine_resume`/`coroutine_wrap_aux` fast paths (x64 and arm64),
`ffh_resume` and `lua_resume`, checked before any coroutine state is
mutated; the x64 fast path uses `TMPR` as scratch and re-compares
`L->status` before the existing `je` so the flags are not clobbered.

## Consolidation decision (previous round)

The resume-nesting inheritance had been reverted on branch `fixresume`
(commit `d7e31723`) while the crash was open; the close-time finalizer part
of `453787f2` (`GCState.closing`) and `f3eb7ec0` (closethread /
`coroutine.close` inherit the closer's nesting) were kept.

## Results after the fix (both arches, `-joff` and `-jon`)

`tests/d54/err_06_coro_ccallnest.lua` matches PUC 5.4.9 exactly:

```
top | 0
wrap | -1
resume | -1
nest2 | -2
wrap2 | -2
resume_at3 | -4
yieldcycle | -1 | -1
```

The resume chain stops at the absolute depth 201 (`level(1)` resumes with
`ccallnest = 200`); PUC stops at 198. The three-level absolute difference is
the same C-call baseline difference that `err_04` deliberately measures as
deltas, not a divergence in the inheritance formula.

`tests/d54/err_07_resume_chain.lua`: every depth returns, 250/300/1000 end
in a caught error, and a `coroutine.wrap` chain at 250/1000 is caught by
`pcall`. The depth-1000 resume probe (`err@800`) exercises the fallback
handler with ~200 nested VM/C frames and returns cleanly.

## Red evidence (fresh `git archive integ7` = d28858b7, before the fix)

x86_64 test host, `-joff` and `-jon` identical:

| | d=196 | d=197 | d=198 | d=199 | d=200 | d=201 | d=202 | d=250 |
|---|---|---|---|---|---|---|---|---|
| PUC 5.4.9 | bottom | bottom | err@1 | err@2 | err@3 | err@4 | err@5 | err@53 |
| ours (old attempt) | bottom | bottom | bottom | bottom | bottom | **SIGSEGV** (rc=139) | | |

aarch64 test host, `-joff` and `-jon` identical with the old attempt: no
crash, but `d=196..200 bottom`, `d=201 err@1`, `d=202 err@2`,
`d=250 err@50` — the bound was reached three levels later than PUC.

Without any inheritance, both arches ran the chain to completion: depth 250
and 1000 returned `bottom`, which is what the red `err_07` assertion
("depth 250 ran past the C-call bound") recorded.

## Mechanism (corrected)

Established with gdb and single-variable builds of the x64 fast path:

1. **The crash needs the `ccallnest` increment to take effect.** Every
   variant whose increment is a no-op survives (the bound then never fires):
   check+branch removed, load only, constant store, check+branch only, and
   `add aword <mem>, imm` (which dynasm silently assembles to nothing — see
   the trap below). This is because no bound fallback is reached.
2. **The crash is not the fallback path.** Replacing only the inserted
   block's `KBASE` with a free scratch register makes the same forced-fallback
   builds clean. The fallback handler is called at the bound and returns the
   error without calling `lj_vm_resume` (`lj_vm_resume` is only the C API
   entry used by `lua_resume`). The depth-1000 probe runs the fallback on a
   ~200-deep VM/C chain and completes with a caught error.
3. **It is not the process C stack.** `ulimit -s 65536` did not change the
   crash depth; the faulting `rsp` was near the top of the stack.
4. **gdb at the fault:** `and 0xc(%rax),%r10d` in `lj_BC_TGETS` with
   `rax = 0x3b` (also `0xb` in an earlier run) — not a stack-guard hit. The
   register is the string constant base read through the clobbered `KBASE`.
5. The old inserted block also sat **after** `mov L:RB->top, PC`, unlike every
   other fallback jump in that handler (all before the state mutation). The
   new code checks before any coroutine state mutation.

## Measured effect of the old formula-only fix (historical)

Applying PUC's formula but keeping the `KBASE` load moved the crash from
d=201 to d=200 — it still crashed. A baseline of 2 moved it to d=198 — still
crashed. Those measurements were about the same register clobber, not about
the reachable depth.

## Remaining (separate from the resume fix)

1. **The close path is unbounded.** `lua_closethread`/`coroutine.close` set
   the closer's count but nothing bounds a deep `__close` chain, where PUC
   errors at 198 through the C call into each handler. Measured on x86_64
   with an 8 MB stack: 100000 nested closes run, 200000 end in SIGSEGV. The
   closed thread is left with a count of zero, so a thread reset by
   `lua_closethread` starts like a new one (main landed that reset).
2. **aarch64/x64 reach the bound three levels deeper than PUC** because
   `ccallnest` is 0-based while PUC's `nCcalls` includes the embedding's C
   frames. The deltas (err_06, err_04) match; a fixed baseline such as
   `LJ_CCALLNEST_BASE` would only approximate it and was not applied.
3. Keep `LJ_MAX_XLEVEL` consistent across the interpreter, the trace counter
   (`lj_record_ccallnest`), the C API and both arches.

## Trap for the next attempt

`add aword <mem>, <imm>` in dynasm silently produces no increment (the count
stays 0 and the bound never fires, which *looks* like a fix). Use
`mov <reg>, ...` / `mov <mem>, <reg>` as the existing pcall fast paths do.
Also never use `KBASE` as scratch in a handler that calls `->vm_resume`: it
is the caller's constants base and is restored from the value at entry.
