# tbcfix: x86_64 SIGSEGV at a plain <close> block exit (2026-11-19)

> **Superseded on main:** the block-exit crash is fixed differently there (MULTRES is used only
> when the UCLO's jump target is RETM; see docs/CHANGELOG-VM.md). This note keeps the analysis,
> and tests/d54/tbc_01_close_frame_top.lua covers the paths it lists.


Branch `tbcfix` from main `f51a7608`. Reported by the downstream round 3
(`docs/notes/downstream-2026-11.md`): `local t2 <close> = setmetatable(...)`
inside a block, then a pcall — SIGSEGV on x64 under `-joff` and `-jon`
(rc 139), PUC prints `true true`, arm64 fine. Interpreter/GC, x64 only.

## Mechanism

`lj_meta_tbcclose` builds the `__close(value, nil)` call frame at
`curr_topL(L) + (multres >> 3)`, added by `6c25e270` so that the frame sits
above the open result slots of a `return f()` in a `<close>` scope
(`CALL`/`CALLM` with B==0 -> `UCLO` -> `RETM`/`RETM`).

But the VM passes its MULTRES scratch register at *every* UCLO. MULTRES is
only live directly after a call with open results; at a plain block exit it
holds whatever the last return path left there. On x64 the handler scaled it
as bytes (`shl CARG3d, 3`); gdb at the crash: `multres = 3192325888`,
`curr_topL(L)` ~ base+2, `top + 8 > maxstack` false for the stale value's
magnitude (or the growth path computed a still-wrong top), then
`setnilV(top+2)` wrote past the stack -> SIGSEGV in `lj_meta_tbcclose`
(backtrace: `lj_meta_tbcclose` <- `lj_BC_UCLO` <- `lua_pcall`).

On arm64 the stale `SAVE_MULTRES` happened to be small enough that the frame
landed only a few slots too high; the close still ran and `RET0`/`RET1`
discarded that region, so the output was right (and the CI gate green).
So the arm was not *correct*, only lucky.

x64 vs arm64 handler line by line: identical shape; the difference is that
x64 scales MULTRES to bytes and the stale value is a large random count
(215.. from a previous frame), while arm64's saved slot still held a small
previous value. Neither has a validity gate.

## Fix

Gate on the UCLO's predecessor, on the C side so both arches share it:
`lj_meta_tbcclose(L, level, multres, pc)` checks `pc[-2]` (pc points after
the UCLO): only a `BC_CALL`/`BC_CALLM` with `bc_b == 0` (open results) makes
the count live; otherwise `openres = 0` and the frame is built at
`curr_topL(L)` exactly.

Bytecode evidence (`-bl`):
- plain block exit: `... TSETS/... UCLO RET0` — predecessor not a call;
- discarded call statement: `CALL 1 1 3` (B=1) then `UCLO` — not open;
- `return f(...)`: `CALL 1 0 3` (B=0) then `UCLO RETM` — open, uses MULTRES;
- nested `return f(9, g())`: `CALLM ... 0` then `UCLO RETM` — open.

VM side: pass PC as CARG4 in the BC_UCLO/BC_TBCCLO handler, x64 and arm64
(x64 POSIX CARG4 == RA, so it is set after CARG1; the existing
`CARG2 == BASE`/`CARG3 == BASE` clobber caveats are unchanged — BASE is saved
in `L->base` and reloaded after the call).

Scanned the other x64 to-be-closed paths for the same mistake: break/goto out
of a block (`TBCCLO`/`UCLO` preceded by JMP -> openres 0), error unwinding
(`lj_meta_tbccloseall`, no MULTRES), `coroutine.close` (same helper), and
multi-result returns (`RETM` *after* the UCLO, so the close still sees the
open call -> gate true). All are covered by the new test.

## Test

`tests/d54/tbc_01_close_frame_top.lua` (mode A/B/R): the original repro, a
discarded call before the block exit, open results in a `<close>` scope,
a nested multret call, break, goto, error unwinding, `coroutine.close`, and
the `__close` arguments. RED on x64 (SIGSEGV, rc 139) on the unchanged tree,
GREEN on arm64 there; green on both arches and PUC after the fix.
