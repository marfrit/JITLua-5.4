# Design: a continuation frame for the `__tostring` call (route, not built)

Base `main` `a6d94a6e`. Design document only: nothing here is built or
measured. Where a fact needs a measurement, it is in section 8 with the exact
command. Predecessors:
[tostring54.md](tostring54.md) (the result check),
[tostring-jit-2026-11-20.md](tostring-jit-2026-11-20.md) (what the recorder
attempt did and why it failed),
[tostring-contframe-2026-11-20.md](tostring-contframe-2026-11-20.md) (why the
recorder cannot retrofit the frame; its review addendum is the route taken
here).

## The route, in one paragraph

`lj_ffh_tostring` (the C fallback of the `tostring` fast function) stops using
`lua_call`. It builds the same frame shape the interpreter's own metamethod
calls build (`mmcall`, `src/lj_meta.c:115-140`) **above its own frame**, puts a
new continuation identity `LJ_CONT_TOSTR` in `frame_contv`, and hands the call
to `->vm_call_dispatch` with `delta|FRAME_CONT` — the way the `pcall` fast path
hands its own frame to the same dispatch (`src/vm_x64.dasc:1645-1670`). The
metamethod frame's `frame_prevd` then lands on the fast function's frame word,
exactly as it does today, so the frame chain, the `debug.getinfo` levels and
the `error(msg, level)` attribution do not move. What is lost is the C frame
`lj_vm_call` used to create, which is what a yield tests; that is the whole
semantic cost, and it is section 3.

The recorder then mirrors the frame in IR slots the way `rec_callt` mirrors the
`LJ_CONT_TAILRET` frame (`src/lj_record.c:1231-1257`) — legal because the real
stack now really has the frame, so `rec_check_slots`
(`src/lj_record.c:117-200`, cont case 164-174) holds — and `lj_record_ret`'s
existing continuation branch (`src/lj_record.c:1423`) gets a case for
`LJ_CONT_TOSTR` that looks at the type of the result reference, converts a
number, and otherwise aborts the trace so the interpreter raises.

## 1. Frame layout, slot by slot

Both gated interpreters are `LJ_FR2` (`x64` in `LJ_GC64`, `arm64`), so the Lua
stack layout is identical on both; the differences are in the C frame chain and
in the dispatch code (section 2). Slot offsets are from the fast function's
base, which is what `L->base` is when `lj_ffh_tostring` runs
(`src/lib_base.c:382-399`).

### Before (today)

```
caller (Lua) frame
  ...                     locals of the caller
  CB+A-2   [func]        the caller's own frame word ... (frame_prevl target)

tostring fast-function frame            BC_CALL: [BASE-8]=resume PC (ins_call)
  base-2   [tostring]    GCfuncC, ffid FF_tostring
  base-1   [resume PC]   bytecode PC after the CALL  (type bits 0 = FRAME_LUA)
  base+0   [o]           argument            <- L->base, L->top = base+1

  base+1   [mo]          pushed by lj_ffh_tostring
  base+2   [o]           pushed
                         L->top = base+3
  -- lua_call(L,1,1): api_call_base moves the argument up and returns base+3;
     lj_vm_call writes (3 slots = 24 bytes)|FRAME_C into the slot at base+2 --

metamethod frame (C)
  base+2   [24|FRAME_C]  frame word          <- frame_prevd -> base-1
  base+3   [o]           metamethod argument <- L->base while it runs
```

Frame delta of the metamethod frame: 3 slots. `frame_prevd` → `base-1`, the
fast function's own frame word — the identity the earlier note measured. There
is a **C frame** in the C-stack chain (`lj_vm_call`'s `saveregs` frame, `L->cframe`
= its `rsp`, bit 0 clear ⇒ not yieldable, `src/lj_frame.h:319`).

### After

```
tostring fast-function frame            unchanged, slot for slot
  base-2   [tostring]    GCfuncC
  base-1   [resume PC]   FRAME_LUA by type bits, untouched

  base+0   [o]           the caller's argument slot, untouched

  base+1   [LJ_CONT_TOSTR]      frame_contv  (= newbase-4)   src/lj_frame.h:118
  base+2   [resume PC]          frame_contpc (= newbase-3)   src/lj_frame.h:117
  base+3   [mo]                 frame_gc/func slot           (= newbase-2)
  base+4   [40|FRAME_CONT]      frame_ftsz                   (= newbase-1)

metamethod frame (continuation)
  base+5   [o]           metamethod argument  <- new base, L->base while it runs
  base+6   ...           scratch (L->top = base+6; fff_fallback already left
                          LUA_MINSTACK of headroom above the argument)
```

Frame delta: 5 slots (40 bytes). `frame_prevd(base+4)` = `base+4 - 40B` =
`base-1` — the **same** slot as today. The cont pair is exactly the
`lj_frame.h:41-45` continuation picture, and equals what `mmcall` lays out
(`cont`, `nil`, `mo`, `nil`, `a`, `b` from `L->top`, new base above it), with
one difference from `mmcall`: `base` (the fast function's frame) stays the
frame *below*, instead of a Lua frame.

`frame_contv` holds the small integer id, not an address — the
`LJ_CONT_TAILRET` mechanism (`src/lj_frame.h:111-114`, built by the VM at
`src/vm_x64.dasc:4675-4713` for `BC_CALLT` to a C function, and by the recorder
at `src/lj_record.c:1247-1248`). That avoids storing a pointer that would need
pointer authentication on `arm64` (`br_auth`, `src/vm_arm64.dasc:705`) and
matches the id compares already in `cont_dispatch`.
`frame_contpc` gets the resume PC: it is what `->cont_tostr` needs as `PC` for
the fast-function return, and what `lj_debug`/`lj_trace` report as the position
of a continuation frame (`src/lj_debug.c:73-74`, `src/lj_trace.c:636-637`).

### Why the observable frame facts do not move

`lj_debug_frame` (`src/lj_debug.c:27-49`) counts every frame; the only skips
are vararg pseudo-frames (42-43) and dummy frames whose function slot is the
thread (32-33, made by `lj_meta_tailcall`). A `FRAME_CONT` frame is **not**
skipped. So from inside the metamethod:

| level | before | after |
|---|---|---|
| 1 | `frame_gc(base+2)`→`mo` (Lua) | `frame_gc(base+4)`→`mo` (Lua) |
| 2 | `frame_prevd`→`base-1`: `[tostring]`, `isluafunc` false → `"C"` | same slot, same function → `"C"` |
| 3 | `frame_islua(base-1)` → `frame_prevl` → the caller (main chunk) | identical |

That is `frame-whats = Lua/C/main` of `tests/d54/tostring_08_cboundary.lua`
held for both layouts, and it is why the levels are *not* the expensive part
of this route (the review addendum's `pcall` argument, which the same code
path confirms: `FRAME_PCALL` and `FRAME_CONT` are both walked by
`frame_prevd` and both counted).

`error(msg, 3)` → `luaL_where` → `lj_debug_frame(L, 3)` (`src/lj_err.c:1351`)
lands on the caller's frame in both layouts; `debug_framepc`
(`src/lj_debug.c:55-121`) derives the caller's position from `frame_pc`, which
is the resume PC in both. `lj_err_callermsg` (`src/lj_err.c:1165-1192`) starts
at `L->base-1`: with the continuation running, `L->base` is the fast function's
base, so `frame_islua` (1170) is true and `pframe = frame_prevl(...)` is the
caller of `tostring` — the same walk as today from `lj_ffh_tostring`, so the
position prefix of `'__tostring' must return a string`
(`lj_strfmt_tolstrres` → `lj_err_caller`, `src/lj_strfmt.c:722`) is unchanged.

Difference in the *C* chain: one fewer cframe. That is only observable through
yieldability and `cframe_nres` walks (section 3, 5).

## 2. Code sites that change, at `a6d94a6e`

### Interpreter / VM

| file:line | change |
|---|---|
| `src/lj_frame.h:114` | `enum { LJ_CONT_TAILCALL, LJ_CONT_FFI_CALLBACK, LJ_CONT_TAILRET, LJ_CONT_TOSTR };` and extend the comment (111-113) to say what `LJ_CONT_TOSTR` returns and where its result slot is. |
| `src/lj_lib.h:28-31` | new handover code `#define FFH_MMCONT (-2)`: the handler built a frame above its own and left the new base in `L->base`, the new top in `L->top`. |
| `src/lib_base.c:382-399` (`LJLIB_ASM(tostring)`) | the metamethod branch: stop using `lua_call` + `lj_strfmt_tolstrres` + `setstrV`. Instead: keep `lj_meta_lookup` (`src/lj_meta.c:68-85`, keeps setting `MM_TOSTR_ABSENT` on a miss); if `mo` is **not** a function, keep the old `lua_call` route (a non-callable method must raise exactly today's message); else write the six slots of section 1 (`setcont`-style `u64` for `LJ_CONT_TOSTR` — `src/lj_obj.h:978-983`, `setframe_pc` for the contpc slot, `copyTV` for `mo` and the argument, `setframe_ftsz(newbase-1, 5*sizeof(TValue) + FRAME_CONT)`), set `L->top = newbase+1`, `L->base` stays, and `return FFH_MMCONT;`. Headroom: `->fff_fallback` already guarantees `LUA_MINSTACK` above the argument (`src/vm_x64.dasc:2375-2381`, `src/vm_arm64.dasc:1988-1996`), which covers 5 slots + 1 arg + the callee's needs at entry. |
| `src/vm_x64.dasc:2369-2399` (`->fff_fallback`) | after the handler returns, before the `test RDd, RDd` at 2393: a branch for `RDd == -2` → `mov RA, L:RB->base` (new base), recompute `NARGS:RD` from `L->top - RA`, `mov PC, [RA-8]` (the `delta|FRAME_CONT` the handler wrote), `jmp ->vm_call_dispatch` (697). `ins_call` (in `->vm_call_dispatch_f`, 701) then writes that value back into the frame word and dispatches the callee, exactly as the `pcall` fast path does with `16+FRAME_PCALL` (1656). |
| `src/vm_arm64.dasc:1984-2012` (`->fff_fallback`) | same: `CRET1w == -2` branch → `RA = L->base`, `NARGS8:RC = L->top - RA`, `PC = [RA, #-8]`, `b ->vm_call_dispatch` (646). |
| `src/vm_x64.dasc:740-765` (`->cont_dispatch`) | add `cmp RA, #3 / je ->cont_tostr` **before** the KBASE reload at 757-760, next to the `cmp RA, #2` at 755 (see the KBASE note below). |
| `src/vm_arm64.dasc:684-705` (`->cont_dispatch`) | the KBASE reload (700-701) sits **before** the id compare (702-703); move the `cmp CARG1, #2/#3` compares above 700, or recompute KBASE in `->cont_tostr` (the recompute already exists as a pattern: `src/vm_arm64.dasc:2323-2334`, "Check frame below fast function"). |
| `src/vm_x64.dasc` new `->cont_tostr`, `src/vm_arm64.dasc` new `->cont_tostr` | the result check + the fast-function return. On entry (after `cont_dispatch`): `BASE` = the fast function's base, `PC` = the resume PC (from `contpc`), `RC`/`RA` = the result TValue address, `RD`/`MULTRES` = `nresults+1`. If the result is a string (`itype == LJ_TSTR`): store it to `[BASE-16]`, `KBASE` fix-up (below), `jmp ->fff_res1` (`src/vm_x64.dasc:1927`, `src/vm_arm64.dasc:1643`). Otherwise: `L->base = BASE`, `L->top = resultptr+1`, `call extern lj_strfmt_tolstrres` (`src/lj_strfmt.c:711`, unchanged signature: string passes, number/int64 converts with the 5.4 number format, anything else raises `LJ_ERR_TOLSTR`), refetch `BASE` from `L->base` (the helper may GC and move the stack), tag the returned `GCstr *`, store to `[BASE-16]`, `KBASE` fix-up, `jmp ->fff_res1`. The number branch of the helper writes the string into the result slot as well, so one store path suffices. |
| `src/vm_x64.dasc:2736-2747` ("Check frame below fast function") | reused, not changed: the arithmetic that sets `KBASE` for the Lua frame below a fast function. `->cont_tostr` must do this because `cont_dispatch`'s own KBASE reload reads `[BASE-16]->pc` of a **GCfuncC**: `pc` is in `GCfuncHeader` (`src/lj_obj.h:486-488`), so for a C function it holds the C-function stub `MRef`, not a `GCproto *` — the reload is safe but useless. Today this is only ever exercised for `LJ_CONT_TAILCALL`/`LJ_CONT_FFI_CALLBACK`, whose handlers ignore KBASE. A trace or the interpreter continuing into the caller with a garbage KBASE is a wrong-constants bug, so `->cont_tostr` recomputes it (7 instructions on `x64`). |
| `src/vm_x64.dasc:1483-1512`, `src/vm_arm64.dasc:1285-1310` (`.ffunc_1 tostring`) | unchanged: the inline string (guarded by `MM_TOSTR_ABSENT`, 1495 / 1296) and number paths stay. |
| `src/vm_x64.dasc:1645-1670`, `src/vm_arm64.dasc:1408-1450` (`pcall`/`xpcall` ff) | unchanged; they are the precedent for a fast function that stays on the frame chain below the function it calls, and the model for the `->fff_fallback` handover. |

### Result-check helper

`src/lj_strfmt.c:707-724` — no change to `lj_strfmt_tolstrres` itself. If the
`L->top` dance in asm proves awkward, add `lj_strfmt_tolstrres_at(lua_State *L,
TValue *res)` next to it and have both call one body; the error must stay
`lj_err_caller(L, LJ_ERR_TOLSTR)` so the message and its position prefix stay
(`src/lj_err.c:1165-1192`).

### Recorder

| file:line | change |
|---|---|
| `src/lj_ffrecord.c:568-596` (`recff_tostring`) | replace the unconditional `recff_nyiu` at 577-580. Keep `recff_has_tostring` (554-566) — it is what guards the lookup (metatable, absent field). Then: if `ix.mobjv` is **not** a Lua function (`isluafunc`), keep `recff_nyiu(J, rd)` — a C/fast-function `__tostring` (FFI cdata, `src/lib_ffi.c:143` etc.) cannot be inlined; else build the IR mirror of the frame (next row) and `lj_record_call(J, func, 1)`, `rd->nres = -1` (pending call). |
| new `rec_tostr_prep` in `src/lj_ffrecord.c` (or a `src/lj_record.c:1509-1522` variant of `rec_mm_prep`) | mirror `cont`/`contpc`/`func`/`arg`: `J->base[top] = lj_ir_k64(J, IR_KNUM, (uint64_t)LJ_CONT_TOSTR)`, `J->base[top+1] = TREF_CONT` (the contpc slot has no IR value — that is what `rec_callt` does at `src/lj_record.c:1247-1248`, and `src/lj_snap.c:78-82` materialises such slots from the real stack), then `func = top+3`, clear the gap (as `rec_mm_prep` does at 1519-1520), write `mo` and the argument into both the IR slots and the real slots (`copyTV`) so `rec_call_setup`'s `functv` (`src/lj_record.c:1134`) is right, and `J->framedepth += 2`. Use `curr_proto(J->L)->framesize` as the top, like `rec_mm_prep` (1511) — the metamethod's own frame slots are above the visible maxslot. |
| `src/lj_record.c:1423-1502` (`lj_record_ret`, continuation branch) | add `else if (frame_contv(frame) == LJ_CONT_TOSTR)`: after the generic pop (1439-1443), look at the type of the result TRef: a string passes through; `num`/`int`/`int64` is converted with the same IR the no-metamethod path uses (`IR_TOSTR` with `IRTOSTR_NUM`/`IRTOSTR_INT`, `IRCALL_lj_strfmt_i64` for int64, cf. `src/lj_ffrecord.c:581-589`); anything else — table, userdata, nil, boolean, function, thread — `lj_trace_err(J, ...)` (a new `LJ_TRERR_TOLSTR` code, or reuse `LJ_TRERR_TYERR`) so the trace exits and the interpreter raises. Then place the converted string in the fast function's result slot (`J->base[-1-LJ_FR2]` after the pop) and continue as a fast-function return. |
| `src/lj_record.c:1426-1437` | extend the existing rule: a trace *rooted inside* the metamethod (`J->framedepth == 2`) must stop with `LJ_TRLINK_RETURN` for `LJ_CONT_TOSTR` too, not just `LJ_CONT_TAILRET`; past the pop, the snapshot would pair the metamethod's `RET` pc with the base of the fast function's caller. |
| `src/lj_record.c:117-200` | no change; the assertion now holds because the real stack has the frame (`cont` slot compared at 164-171, "cont slot not followed by frame" at 172-173 satisfied by `base+3`/`base+4`). This is the exact assertion that fired in the earlier attempt. |
| `src/lj_snap.c:72-83`, `136-158` | no change: `snapshot_stack` walks `frame_iscont` (142) and the frame/cont words become `IR_KNUM` constants taken from the real stack (78-82), so an exit restores the whole cont frame and `L->base` (`src/lj_snap.c:1029`). |
| `src/lj_ir.h:200` area, `src/lj_record.c:1312-1329` | only if the yield counter (option B, section 3) is taken: mirror `lj_record_ccallnest`/`rec_ccallnest_flush` for the new counter, and add the corresponding `IRFL_THREAD_*` field. |

### Counter sites (option B only)

`src/lj_obj.h:769-784` (a new `MSize tostrnest;`, placed after `ccallbase` so
no existing offset moves — the comment at 770-778 explains that discipline),
`src/lj_state.c:292-301` and `:403` (init), `src/lj_api.c:1808-1811`
(`lua_isyieldable`), `:1813-1820` (`lua_yield`), `:1890-1935` (resume
inheritance), `src/lib_base.c:695/711/778/811` (coroutine resume/close/wrap),
`src/lib_base.c:731-735` (`coroutine_isyieldable`), `src/vm_x64.dasc:1879-1885`
and `src/vm_arm64.dasc:1600-1610` (the `coroutine_yield` fast path tests
`cframe & CFRAME_RESUME`; the counter test goes next to it, with the same
`->fff_fallback` error route), `src/lj_err.c:228-234` (`err_unwind`'s
`FRAME_CONT` case, decrement per dropped `LJ_CONT_TOSTR` frame),
`src/lj_err.c:129-131` (`tbc_hascatcher`, no counter effect but it walks the
same frames), `src/lj_snap.c` restore (add the count for every cont frame in a
restored snapshot), and `src/lj_record.c` for the trace-side store.

## 3. The `tostring_08` properties, one by one

`tests/d54/tostring_08_cboundary.lua` pins six things. Mode A compares them
with PUC 5.4.9, mode B compares `-joff` with `-jon`.

1. **`frame-whats` (`Lua/C/main`)** — preserved for free, section 1: the
   metamethod frame's `frame_prevd` is the same slot, and the fast function's
   frame is a `GCfuncC` frame either way (`src/lj_debug.c:607`,
   `:621-630`).
2. **`level3` (`error("L3", 3)` → the caller of `tostring`)** — preserved for
   free: `lj_debug_frame(L, 3)` walks the same three frames
   (`src/lj_debug.c:27-49`), and `luaL_where` (`src/lj_err.c:1351`) takes its
   position from the third. The interpreter's own metamethods differ here
   precisely because their cont frame sits where the fast function's frame was
   (the note's `__add` observation); that does not happen here because the
   fast function keeps its frame.
3. **`mm-error` (an error raised inside the metamethod reports the
   metamethod's own line)** — preserved: the error is raised while the
   metamethod is the running function (`L->base` = the cont frame's base), so
   `debug_addloc`/`lj_debug_addloc_rt` (`src/lj_debug.c:519-529`) use its
   frame. Unwinding changes shape but not reach: `err_unwind`
   (`src/lj_err.c:158-257`) pops a `FRAME_CONT` with `frame_prevd` (228-234)
   and reaches the same `FRAME_PCALL` frame (235-256) → `CFRAME_UNWIND_FF` →
   `->vm_unwind_ff` (`src/vm_x64.dasc:548-560`) which counts `ccallnest` out
   as before. Today's path additionally unwinds a real C frame; nothing in the
   message depends on it.
4. **Hooks.** The metamethod call fires **no** call hook in either route:
   `lj_dispatch_call` is only reached from the bytecode call sites
   (`src/vm_x64.dasc:2540`, `src/vm_arm64.dasc:2146`), and both the old
   `lj_vm_call` route and the new `->vm_call_dispatch` route bypass it. The
   fast function's return hook still fires because the continuation returns
   through `->fff_res`, whose hook branch calls `lj_dispatch_ffret`
   (`src/vm_x64.dasc:1955-1965`, `src/vm_arm64.dasc:1648-1649`) with `L->base`
   = the fast function's base and `PC` = the resume PC — the same values as the
   direct fast-function return, and the same level for a hook that calls
   `debug.getinfo`. `ffretry` (`src/vm_x64.dasc:2396`) is untouched: `FFH_MMCONT`
   is a third return code, not a retry. Open question Q1: whether PUC fires a
   call hook for the `__tostring` call at all, and whether mode A already
   tolerates the difference.
5. **`yield-direct` / `yield-deep` (`attempt to yield across a C-call
   boundary`)** — **this is the property the route breaks.** The message comes
   from the `coroutine_yield` fast path falling back to
   `LJLIB_ASM(coroutine_yield)` (`src/lib_base.c:747-754`), and the fast path
   decides with `cframe_canyield(L->cframe)`
   (`src/vm_x64.dasc:1881`, `src/vm_arm64.dasc:1600`; `src/lj_frame.h:319`):
   bit 0 (`CFRAME_RESUME`) is set only by `->vm_resume`
   (`src/vm_x64.dasc:633`). Today `lj_vm_call` pushes a cframe with that bit
   clear, so the yield is refused; without that frame, the innermost cframe is
   again the resume frame and the yield **would succeed** — which is exactly
   what `__add` and friends do today. Two ways out:
   - **Option A — accept it.** Drop the two yield cases from
     `tostring_08_cboundary.lua` (keeping `yield-print`/`yield-format`, which
     keep their C frames because `print` and `string.format` still call
     through C), add a row to `docs/DIFFERENCES.md`, and state the trade.
     Cheap, and it moves the difference into the same class as the interpreter's
     own metamethods. Risk: it is a visible divergence from PUC 5.4.9 in a
     5.4-focused tree.
   - **Option B — keep the count.** A per-thread `L->tostrnest`, incremented
     where the frame is built (`lj_ffh_tostring`, plus the recorder if a trace
     builds one), decremented in `->cont_tostr`, decremented by `err_unwind`
     for every dropped `LJ_CONT_TOSTR` frame, added by `lj_snap_restore` for
     every such frame of a restored snapshot, and tested by the
     `coroutine_yield` fast path, `lua_yield`, `lua_isyieldable` and
     `coroutine_isyieldable`. That is the `L->ccallnest` bookkeeping
     (`src/lj_obj.h:769-784`, `src/vm_x64.dasc:414-418`, `:556-560`,
     `:1649-1681`, `src/lib_base.c:695-811`, `src/lj_api.c:1890-1935`,
     `src/lj_record.c:1294-1329`) with the same failure mode: one missed path
     leaks the count and every later yield in that thread is wrong. The
     `ccallbase` companion shows a second subtlety: a count inherited by a
     coroutine resume must not be counted twice.
   Recommendation: build the route with option A first (it is one test change
   and one `DIFFERENCES.md` row), then decide B from whether the yield case is
   considered a 5.4 difference worth 10+ sites. Section 5 ranks the risk of B;
   section 6 splits the steps accordingly.
6. **`yield-print` / `yield-format`** — untouched: `print` and
   `string.format("%s")` still reach `lj_strfmt_tolstrres` through their own C
   code (`src/lj_strfmt.c:544`), and `src/lj_ffrecord.c:1363,1371` keep sending
   those cases to the interpreter.

## 4. The recorder side

**Snapshot and continuation shape.** The IR slot block for the mirrored frame
(with `LJ_FR2`, slots relative to the fast function's frame, `top` = the
metamethod proto's `framesize` as in `rec_mm_prep`):

| slot | IR slot | real slot |
|---|---|---|
| `top` | `IR_KNUM` of `(uint64_t)LJ_CONT_TOSTR` | the id |
| `top+1` | `TREF_CONT`, no ref | the resume PC |
| `top+2` (`func`) | the metamethod `TREF_FUNC`/`KGC` | `mo` |
| `top+3` | `TREF_FRAME`, no ref | `40|FRAME_CONT` |
| `top+4` | the object TRef | `o` |

`J->framedepth += 2` (a continuation counts twice, as in
`src/lj_record.c:1251`). Because the real stack has the frame, `rec_check_slots`
passes and `lj_snap.c:78-82` can materialise `top+1`/`top+3` as constants from
it — this is what makes an exit inside the metamethod restorable.

**Guard IR.** The lookup guards are already emitted by `recff_has_tostring`
(`src/lj_ffrecord.c:554-566` → `lj_record_mm_lookup`): metatable identity,
absent-field guard where a metatable exists, nothing where it does not
(`lua_setmetatable` flushes). The callee is specialised with the function
identity guard from `rec_call_specialize` (`src/lj_record.c:1096-1128`).
**The result check needs no new guard IR**: as the batch-6 review put it, every
load is already type-guarded, so the type of the result reference is known at
recording time. The check in `lj_record_ret` is a *recording-time* decision on
that static type — a string continues, a number is converted with the same IR
as the untraced path, anything else aborts the trace once, at recording time,
and the loop then runs in the interpreter, where the interpreter raises the 5.4
error. A trace that recorded a string result keeps its correctness from the
guards that already exist: the result value's own guard (for a value read from
a field or an upvalue, the load guard fires the moment the type changes), the
metamethod function-identity guard (replacing the method ends the trace), and
the guards inside the metamethod body (a body that switches its result type
carries its own branch/guard, which is how `tostring_07_hot_bad.lua`'s
late-bad cases must behave).

**Exits.**

- *Exit inside the metamethod* (any guard failure in its body): the snapshot
  above the `tostring` call contains the cont frame; `lj_snap_restore` writes
  the frame word and the cont id back from the snapshotted constants and sets
  `L->base` to the metamethod's base, so the interpreter continues inside the
  metamethod and its `return` reaches `cont_dispatch` normally. No re-run of
  the conversion, no state to repair — except under option B, where the
  restored cont frame must restore the counter.
- *Abort while recording* (a `lj_trace_err` inside the inlined metamethod):
  the trace is abandoned; the real stack is exactly what the interpreter built
  before the call, and the fast function's own frame is still intact, so the
  interpreter re-enters `tostring` normally. Unlike `recff_stitch`
  (`src/lj_ffrecord.c:125-174`) this route invents nothing on the real stack,
  so there is no `memmove` to undo.
- *A metamethod body that cannot be traced at all* (a C call inside, an
  unsupported construct, a nested `tostring` of another object, the frame or
  slot budget `LJ_MAX_JSLOTS` at `src/lj_record.c:1174-1175`): the recording
  aborts at that point (`LJ_TRERR_*`, possibly `NYI`), the whole loop is left
  to the interpreter, and behaviour is today's. If the loop re-hotens, the
  recorder retries and the same abort repeats — today's `tostring` exit already
  behaves like that; the new thing is that the *whole* loop trace can be lost
  instead of just exiting at the call. `tests/lib/ffrec-54.lua` is the
  instrument (see the risk list).
- *A trace rooted inside the metamethod* (hotcall fires inside its body):
  `lj_record_ret` must stop with `LJ_TRLINK_RETURN` before popping the cont
  frame — the rule that already exists for `LJ_CONT_TAILRET` at
  `src/lj_record.c:1426-1437`, extended to `LJ_CONT_TOSTR`.
- *A C/fast-function metamethod*: refused before any frame is mirrored (the
  `isluafunc` check), keeping today's `recff_nyiu` exit. The interpreter, in
  contrast, does **not** need to distinguish: BC_FUNCC does not rewrite the
  frame word, so a C callee under a cont frame already works — that is how a C
  `__index` works today through `->vmeta_tget_mm`
  (`src/vm_x64.dasc:859-868`), and it is how `tostring(cdata)` will now run:
  cont frame, `BC_FUNCC`, `cont_tostr`, result check.

## 5. Risks, ranked, with the test that catches each

1. **Yield counter leak (option B).** Failure mode: a leaked count makes every
   later yield in that thread raise, or a lost count lets a yield escape where
   PUC refuses it. Catch: a new `tests/d54/tostring_10_contframe.lua` (mode A
   and B, both arches) with the paths that drop or restore the frame without
   running the continuation — yield directly in `__tostring`; yield one level
   deeper; `error()` in `__tostring` caught by a `pcall` *in the same
   coroutine*, then `coroutine.yield` afterwards; a trace exit inside the
   metamethod (hot loop, a guard that fails once) followed by a yield;
   `coroutine.create`/`resume` *from inside* the metamethod; a nested
   `tostring` (a metamethod that converts another object) to check counting of
   two open frames; `coroutine.isyieldable()` in each; and
   `pcall(tostring, o)` followed by a yield in the same coroutine. Under
   option A the same file records the difference instead, plus a
   `docs/DIFFERENCES.md` row.
2. **KBASE after `cont_dispatch`** (section 2): a continuation that continues
   into the caller with a KBASE derived from a `GCfuncC` reads constants from
   the C-function stub area. Catch: `tostring_10` — a hot `tostring` loop where
   the metamethod reads an upvalue/local of the *caller* afterwards, plus
   `debug.getinfo(2,"l")` inside the metamethod and a line hook during the
   loop, `-joff` and `-jon`, on both arches (the two arches differ in where the
   KBASE load sits: `src/vm_x64.dasc:757` vs `src/vm_arm64.dasc:700`).
3. **Stack reallocation across the result-check helper** (`lj_gc_check` inside
   `lj_strfmt_tolstrres`, `src/lj_strfmt.c:717`) if the asm keeps `BASE`/result
   pointers across the call. Catch: `tostring_10` with a metamethod returning a
   number under a lowered `collectgarbage("setpause")`/GC stress stage (the CI
   GC-stress stage of `tests/ci-box.sh` runs the d54 corpus) and an
   out-of-memory variant via a memory-limit probe.
4. **A trace that inlines the metamethod loses the loop when the body is not
   recordable** — a performance regression that no correctness test sees.
   Catch: `tests/lib/ffrec-54.lua` with the two loops registered in `loop_fns`
   (97-117, exemption comment at 113-117) plus a third loop whose metamethod
   calls a C function (`math.floor` of a string, `string.rep`), asserted *not*
   to compile (so the abort is deliberate and visible).
5. **Snapshot/frame mismatch on an exit inside the metamethod** (frame word or
   cont id restored wrongly ⇒ the interpreter's next `return` jumps to a bogus
   continuation). Catch: `rec_check_slots` under `-DLUA_USE_ASSERT
   -DLUA_USE_APICHECK` over `tests/d54/tostring_*` and `tests/lib/ffrec-54.lua`
   in all modes, which is the build the batch-6 review ran; plus the
   trace-exit-then-yield case of risk 1.
6. **Unwinding with `<close>`/to-be-closed variables**: an error inside the
   metamethod must still reach the catcher test (`tbc_hascatcher`,
   `src/lj_err.c:119-137`, whose `FRAME_CONT` fallthrough already works) and run
   the handlers of the dropped frames. Catch: extend `tostring_10` with a
   `<close>` variable in scope around `tostring(o)` whose metamethod raises,
   compared with PUC (mode A).
7. **A C `__tostring` under the cont frame** (`tostring(cdata)`,
   `tostring(udata)`) — output and error text must not change, and the
   `frame-whats` chain must not gain a level. Catch: the existing FFI corpus
   stage plus a `tostring_10` case for `tostring(cdata)`.
8. **Frame-slot growth**: `tostring` recursion (a metamethod that converts the
   same object) uses 6 more slots per level than before, so "stack overflow"
   arrives at a slightly different depth. Catch: a recursion-depth probe printed
   modulo nothing — pinned as an exact depth only if a decision is made; today
   the tree already differs from PUC ("stack overflow" vs "C stack overflow",
   recorded in `tostring54.md`).
9. **The `LJ_CONT_TOSTR` id colliding with an id compare.** Only 0/1/2 are
   compared today (`cont_dispatch` on both arches, `frame_iscont_fficb` at
   `src/lj_frame.h:133`, `src/lj_crecord.c:1619`). Catch: a build-time assert
   that the new id is `> LJ_CONT_TAILRET` and the `x64`/`arm64` compares updated
   in lockstep; no runtime test.

## 6. Step plan (red tests first) and effort

| # | step | red/green | effort |
|---|---|---|---|
| 0 | New `tests/d54/tostring_10_contframe.lua` pinning **today's** behaviour (frame levels, `error(_,3)`, mm error line, hooks, `<close>`, `isyieldable`, nested `tostring`) and, separately, the two `tostring_mm` loops registered in `loop_fns` of `tests/lib/ffrec-54.lua`. The frame/hook cases are green now, the loop registration is red (already known red: "did not compile to a root loop trace"). | pins the ground | 2-3 h |
| 1 | Interpreter, `x64` only: `FFH_MMCONT`, the frame build in `lj_ffh_tostring`, the `->fff_fallback` branch, `->cont_tostr`, `LJ_CONT_TOSTR`. Run the d54 corpus + `tostring_10` (yield cases expected to change under option A). | 0 turns red only on yield | 0.5-1 day |
| 2 | Same on `arm64` (`cont_dispatch` compare order, `->fff_fallback`, `->cont_tostr`). | both arches agree | 0.5 day |
| 3 | Yield decision: option A (edit `tostring_08_cboundary.lua`, `tostring_10`, add a `DIFFERENCES.md` row) **or** option B (the counter across the sites in section 2, both arches, trace side included). | A green, B needs risk-1 tests | A: 1-2 h. B: 1-2 days |
| 4 | Recorder: `recff_tostring` frame mirror + `isluafunc` refusal, the `lj_record_ret` branch with the result check, the rooted-inside-metamethod rule, then the `rec_tostrres` conversions (num/int/int64). Register the two `ffrec-54` loops. | the two loop tests turn green; `tostring_07_hot_bad` must stay green in mode B | 1 day |
| 5 | `tests/d54/tostring_07_hot_bad.lua`-style cases for the traced path where the metamethod turns bad *after* compiling, and the C-`__tostring` refusal; `tostring_09_format_i64mt.lua` must not regress. | risk 4/7 | 3-4 h |
| 6 | Bench: `tests/bench/b6_tostring.lua` base-vs-head interleaved, plus the per-call number; update `tostring54.md`, `tostring-jit-2026-11-20.md`, `tostring-contframe-2026-11-20.md` (their titles and conclusions need the "ruled out: a recorder-retrofitted frame only" qualifier the addendum already states) and this note. | numbers | 3-4 h |
| 7 | Gates: `tests/ci-box.sh` on both arches, `tests/ci-local.sh --sanitizers-only`, `tests/harness.sh --mode all --strict`, the d54 corpus stage, opt levels 0-3, GC stress, and an assert build over `tests/d54/tostring_*` + `tests/lib/ffrec-54.lua`. | — | 0.5 day of waiting |

Total: about 3 focused days with option A, 4-5 with option B, plus review. The
review's estimate ("one focused session plus a review") is realistic only for
steps 1, 2 and 4 with option A; the yield bookkeeping and the tests are what
the days go into.

## 7. Expected gain, checked against the reading

The review's figure: about 90 ns per call saved on the measured box, from
"182 ms for 2M calls". The arithmetic is right (182 ms / 2M = 91 ns/call), and
my reading of the published numbers agrees that this is the *cost of the trace
exit today*, but it overstates what the route recovers:

- `b6_tostring.lua` `obj` case, N = 2M: 2.4 ms traced *before* `tostring54`
  (1.2 ns/call), 182 ms after (91 ns/call), and **149 ms with `-joff`**
  (74.5 ns/call) — see `tostring54.md`'s bench table. So the traced cost today
  is *worse* than the interpreter, and the ceiling for a real (non-hoisted)
  conversion is the interpreter's own cost of the metamethod call, not 1.2 ns.
  Best case for the `obj` case: 182 ms → roughly the `-joff` figure, i.e. a
  saving of ~30 ns/call, not 90.
- The 2.4 ms of the pre-`tostring54` trace is a metamethod that returns a
  constant, which the old trace hoisted entirely (the review says the same
  thing: that case measured hoisting, not conversion). That number is **not**
  reachable again with a guarded call, because the guard and the conversion of
  the string result are real work per call.
- What is really removed per call: the C fallback entry (`->fff_fallback` + the
  C handler + `api_call_base` + `lj_vm_call`'s `saveregs`/`L->cframe`
  bookkeeping), the C frame's unwind setup, and the trace exit + re-entry. That
  is the ~90 ns of the review, and it is the *cost of today's exit*, which is
  why removing it can only get back to about the interpreter's cost.
- The older "0.1 µs at `-jon` and 0.1 at `-joff`, 0.0 µs on `f8c70a23`" (from
  `tostring-jit-2026-11-20.md`) is the same number rounded until it distinguishes
  nothing; use the bench medians.

Expectation, to be measured, not asserted: `obj` at `-jon` lands between
149 ms (`-joff`, the floor if the trace only ever exits again) and about
60-90 ms (if the whole loop stays one trace and the metamethod inlines). If the
measurement lands near 149 ms, the route buys nothing over `-joff` for this
shape and the plain conclusion is "the trace no longer hurts"; the case where
it clearly wins is a conversion inside a bigger loop that today exits at every
conversion. Measurement command in Q3.

## 8. Open questions, with the command that settles each

All of these need a build; none was run for this document.

1. **Does PUC 5.4.9 fire a `call`/`ret` hook for the `__tostring` call, and
   does LuaJIT today?** (Section 3.4 argues "no" for LuaJIT in both layouts.)
   `cat > /tmp/h.lua <<'EOF'
   local ev={}
   local t=setmetatable({},{__tostring=function() ev[#ev+1]="mm"; return "s" end})
   debug.sethook(function(e) ev[#ev+1]=e .. ":" .. (debug.getinfo(2,"n").name or "?") end, "cr")
   local s=tostring(t); debug.sethook()
   print(s, table.concat(ev," "))
   EOF` then `./src/luajit -joff /tmp/h.lua; ./src/luajit -jon /tmp/h.lua` on
   base `a6d94a6e` and on the patched tree, and the same script under PUC 5.4.9.
2. **Is `coroutine.isyieldable()` false inside `__tostring` today, and does
   mode A already pin it?** `./src/luajit tests/d54/tostring_08_cboundary.lua`
   with one added line printing `coroutine.isyieldable()` in the metamethod,
   `-joff` and `-jon`, compared with PUC 5.4.9 — this decides whether option A
   costs one more difference row or several.
3. **The actual gain.** `for i in 1 2 3 4 5 6 7; do ./base -jon
   tests/bench/b6_tostring.lua; ./head -jon tests/bench/b6_tostring.lua; done`
   interleaved, medians per case (`tostring54.md`'s method), same box, plus the
   `-joff` arms; report `obj` in ms and ns/call. Register the two loops in
   `loop_fns` and require the root-trace assertion to pass:
   `./tests/harness.sh --strict --mode both --corpus tests/lib` (with
   `ffrec-54` selected) as the pass/fail gate.
4. **Trace shape**: does the conversion stay in the root loop trace?
   `./src/luajit -e 'jit.off()' -e '...'` is not enough — use the `jit.util`
   trace handler already in `tests/lib/ffrec-54.lua` and print
   `jit.trace`/`traceinfo` for the two loops; the check is "one root trace per
   loop, no `LJ_TRERR_*` abort, `traceexitnot` small".
5. **KBASE**: does the caller's constants survive the continuation?
   `./src/luajit -jon tests/d54/tostring_10_contframe.lua` with the caller-local
   read and `debug.getinfo(2,"l")` cases, on both arches, and the same file
   with `-joff`; a mismatch is a wrong-constants bug, not a reporting bug.
6. **Exit-inside-metamethod restore** (risk 5): run
   `tests/d54/tostring_10_contframe.lua` and `tests/lib/ffrec-54.lua` in a
   `-DLUA_USE_ASSERT -DLUA_USE_APICHECK` build (the `ci-local` assert build)
   with `jit.flush()` forced once per iteration, and separately with
   `-DLUAJIT_ENABLE_CHECKSOFT`? — check what the tree's assert knobs are named
   before running; the point is an assert build over those two files in modes
   A/B/R.
7. **Depth of the slot-cost change** (risk 8):
   `./src/luajit -e 'local t setmetatable...'` — a recursion probe:
   `local t = setmetatable({}, {__tostring=function() return tostring(t) end});
   local ok,e = pcall(function() tostring(t) end); print(e)` on base and head,
   and under PUC 5.4.9; decide whether to pin the depth or leave the (already
   different) "stack overflow" wording alone.
8. **`LJ_CONT_TOSTR` id**: grep-only, no build —
   `grep -rn "frame_contv\|LJ_CONT_" src | grep -v lj_frame.h` must show only
   the compares already listed in risk 9.
