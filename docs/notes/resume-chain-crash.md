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

With `LJ_CCALLNEST_BASE` 3 the resume chain stops at the absolute depth 198
(`level(1)` resumes with `ccallnest = 200`), the same as PUC. Without the
baseline it stopped at 201; the three-level difference was the C-call baseline
difference that `err_04` measures as deltas, not a divergence in the
inheritance formula.

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

## Close-path follow-up (same round)

`lua_closethread`, `coroutine.close` and the wrap-error close set the closed
thread's count to the closer's count + 1 but nothing bounded it. A pure close
chain (each suspended coroutine's `__close` closes the next suspended one, no
resume inside the handler) ran on until the native stack died: SIGSEGV at
depth 200000 on x86_64 and aarch64, `-joff` and `-jon`; depths up to 1000
completed silently.

PUC raises the bound when the C call into the first `__close` handler would
reach 200. LuaJIT does not make that C call, so the check moved into
`lj_meta_tbccloseall`: the call sites already store closer+1, and the helper
raises `C stack overflow` into the error slot when that count is already at
the bound and `L->tbcn > 0`. With no pending handler PUC does not error, so the
guard is skipped. Before the handler can run, no throw is needed: the close
returns false plus the error, exactly as PUC's `coroutine.close` does.

Result (both arches, `-joff`/`-jon`, `tests/d54/err_09_close_chain.lua`):
`d=196/197 fail=none`, `d=198..200000 fail=197 msg=C stack overflow`, matching
PUC 5.4.9 line for line. No crash at 200000.

A close that is refused at the bound drops the pending slots, as PUC has
done by the time it returns the error. They used to stay registered on the
reset thread, and a thread reset by `lua_closethread` is used again: the next
function's to-be-closed value was then closed a second time through the stale
slot (`tests/capi` "close at the bound").

## Frames a coroutine is suspended in

The first version stored `resumer + 1` into the count on every resume and
left the rest alone. A coroutine that had yielded inside k pcall frames still
had those k frames on its stack; each of them took one off the count when it
returned. After the resume the count was therefore k too low, and with k
larger than the resumer's count it wrapped below zero, which made the next
pcall in that coroutine fail with "C stack overflow":

```lua
local function nest(k)
  if k == 0 then coroutine.yield() return end
  assert(pcall(nest, k - 1))
end
local co = coroutine.wrap(function()
  nest(10)
  return pcall(function() return "fine" end)
end)
co()
print(pcall(co))   -- PUC: true true fine; was: false C stack overflow
```

From C the same happened with two pending frames and `from == NULL`.

In PUC the frames that were pending at the yield no longer count after the
resume (their C levels are gone, `lua_resume` sets `nCcalls` anew) and
nothing is subtracted when they finish. The count here does the same now:
every place that gives a thread its count stores it a second time in
`ccallbase`, and a returning pcall frame (`vm_returnp`, `vm_unwind_ff`, x64
and arm64) does not count below that value. Frames entered after the resume
count in and out as before. Compiled code needs no change: a trace only
returns through pcall frames it entered itself.
`tests/d54/err_10_resume_pending_pcall.lua` matches PUC 5.4.9 line for line,
including the depth seen inside the pending frames after the resume.

## Baseline alignment

The main thread now starts with `LJ_CCALLNEST_BASE` 3. PUC's `nCcalls` counts
the C frames that entered the main chunk (the standalone's `lua_cpcall`/
`lua_pcall`), while `ccallnest` counts only the pcall/xpcall fast paths; the
fixed baseline stands in for those frames. It is a one-line change at state
creation and it shifts every absolute depth by the same 3:

* pcall depth: 200 -> 197 (PUC 197)
* resume chain first error `err@1`: depth 201 -> 198 (PUC 198)
* close chain failure: the close of thread 201 -> 198 (PUC 198)

All deltas are unchanged (err_06, err_04, close_05 still match), because both
the top-level depth and the inherited counts shift together. It is an
approximation for other embeddings, where the host's own C frames differ;
those environments keep the documented delta behaviour.

## Remaining

1. Keep `LJ_MAX_XLEVEL` consistent across the interpreter, the trace counter
   (`lj_record_ccallnest`), the C API and both arches.
2. The baseline is fixed, not measured per embedding (see above); it matches
   the standalone oracle used by the differential harness.

## Trap for the next attempt

`add aword <mem>, <imm>` in dynasm silently produces no increment (the count
stays 0 and the bound never fires, which *looks* like a fix). Use
`mov <reg>, ...` / `mov <mem>, <reg>` as the existing pcall fast paths do.
Also never use `KBASE` as scratch in a handler that calls `->vm_resume`: it
is the caller's constants base and is restored from the value at entry.
