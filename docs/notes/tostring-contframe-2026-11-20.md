# The `__tostring` call cannot carry a continuation frame (branch `tostringrec`)

Follow-up to [tostring-jit-2026-11-20.md](tostring-jit-2026-11-20.md), whose
ticket step 1 was: build the continuation frame for the `__tostring` call
physically, the way `recff_stitch` does, and teach `lj_record_ret` to step over
it. This note is the check of that step against the frame layout: **it cannot be
built**, because the slot the continuation marker would have to live in is the
slot the interpreter's fast-function return path reads as the resume PC. Step 3
(the result guard) is unaffected and stays re-usable; the routes that could
work are at the end. Nothing here is a behavioural change: the tests pin what
is true today.

## The frames, measured

`x64`, `LJ_FR2`, probe build (dump of the real chain while `recff_tostring`
records the call; `frame@` is the frame-info slot, `type` per `lj_frame.h`):

```
PROBE ff-tostring-mm: L->base=0x7fd95b518680 L->top=0x7fd95b518688 framedepth=2 baseslot=10 maxslot=1
  frame@0x7fd95b518678 type=0 ... ftsz=0x7fd95b51855c   -- FRAME_LUA: holds the caller's resume PC
  frame@0x7fd95b518638 type=3 ...                        -- FRAME_VARG (main chunk)
  frame@0x7fd95b518628 type=1 ...                        -- FRAME_C
```

`L->top = L->base+1`: one argument, no frame of its own for the fast function —
`BC_CALL` set `L->base` and stored the resume PC in `L->base-1` (`ins_call`),
`BC_FUNCC` only calls the C function (`vm_x64.dasc`).

`lj_ffh_tostring` (lib_base.c) then pushes the method and the object at
`base+1`, `base+2` and calls `lua_call`. `api_call_base` (lj_api.c) moves the
argument up and returns the metamethod base `base+3`, and `lj_vm_call`
(`->vm_call`: `mov PCd, FRAME_C` … `add PC, RA; sub PC, BASE`) writes
`(delta + FRAME_C)` into the slot at `base+2`, with `delta = 3` slots. So:

```
base-2  base-1     base+0   base+1  base+2      base+3 ...
[ff]    [resumePC]  (o)     [mo]    [d3|C]      [o]      <- metamethod frame, FRAME_C
```

`frame_prevd` of that frame is `(base+2) - 3 = base-1`, i.e. **always** the fast
function's own frame-info slot. The two move together: any `memmove` that shifts
the fast function's frame up by `k` slots shifts the metamethod frame up by the
same `k` (its position is derived from `L->base`), so the identity is not an
accident of this placement — it holds for the `recff_stitch` pattern too
(`L->base += 2+LJ_FR2` moves both). A `FRAME_CONT` marker has to sit in the
previous frame-info slot of the chain, i.e. in `base-1`, with its `cont`/`contpc`
in the two slots below; `base-1` is what `BC_FUNCC` reads back after the C call
(`mov PC, [BASE-8]`), and its low bits must stay `FRAME_LUA` with the value a
PC. Overwriting it makes the real return jump to the continuation pointer.
`base` (the `contpc` slot) holds the argument until the call.

The same dump in the `-DLUA_USE_ASSERT` build segfaults inside the recorder's
own slot check once the IR describes a continuation the real stack does not
have: `rec_check_slots` requires `ir_knum(ir)->u64 == tv->u64` for a
`TREF_CONT` slot — the predecessor's `LJ_TRERR_NYIRETL` was the non-assert
symptom of the same mismatch.

## The frame shape is observable, and PUC-equal

`tests/d54/tostring_08_cboundary.lua` (new; identical output with `-joff`,
`-jon` and PUC 5.4.9):

```
yield-direct  false  attempt to yield across a C-call boundary  dead
yield-deep    false  attempt to yield across a C-call boundary  dead
yield-print   false  attempt to yield across a C-call boundary
yield-format  false  attempt to yield across a C-call boundary
frame-whats   Lua/C/main
level3        false  T.lua:70: L3
```

`frame-whats` is `debug.getinfo(1/2/3,"S").what` from inside the metamethod: the
conversion above it is a **C** frame. `level3` is `error("L3", 3)` — attributed
to the caller of `tostring()`, again counting the conversion as a level. The
interpreter's own metamethods, which *do* use a continuation frame, look
different (scratch check, not committed): `error("A3", 3)` inside `__add`
reports no position at all, and a `coroutine.yield()` inside `__add`, `__len`,
`__index`, `__call`, `__concat` or `__lt` yields fine, while inside
`__tostring` it errors like PUC.

So the C-call boundary of `__tostring` is not an implementation detail: it is
what makes the yield behaviour and the error levels match PUC 5.4.9. Any change
that removes the boundary has to re-create both.

## What this leaves

The recorder cannot follow this call as it follows `__add`/`__len`/`__index`:
`lj_record_ret` starts its walk at `J->L->base-1`, which here is a `FRAME_C`
frame with no continuation to dispatch to, and the guard of step 3 has nowhere
to attach. Two shapes could carry the trace, both bigger than the ticket:

1. **Hand the call to the VM with a continuation** — `lj_ffh_tostring` uses the
   `mmcall` layout plus a new `lj_cont_tostr` (asm on `x64` *and* `arm64`, like
   `lj_cont_ra` with `lj_strfmt_tolstrres` for the check). Then the existing
   `rec_mm_prep` + `lj_record_ret` continuation branch + the `rec_tostrres`
   guard from the predecessor note work unchanged, and the pre-`tostring54`
   speed is reachable. Cost: no C-call boundary. The yield error and the error
   levels above have to be rebuilt explicitly — a continuation *id* in
   `frame_contv` (the `LJ_CONT_TAILRET` mechanism), checked in the yield path,
   plus the `level`/`what` reporting; on both architectures.
2. **Keep the C call and describe the frame only in the IR** — the metamethod
   frame can be mirrored exactly (`mo` at `base+1`, frame slot `base+2`,
   argument `base+3`, no continuation slot at all, so `rec_check_slots` stays
   satisfied) and the walk can be taught to pop that frame when the fast
   function armed it, then continue with the Lua frame below as it already does
   for a fast-function return. Cost: a trace exit taken *inside* the inlined
   metamethod resumes the interpreter inside a function whose caller C frame
   does not exist at trace runtime (the `lj_vm_call` frame existed only in the
   interpreter run that preceded compilation). Safe options: let every such exit
   unwind to the state *before* the `tostring` call (the interpreter re-runs the
   conversion — correct, but the trace is then left at every exit inside the
   metamethod), or reconstruct a continuation frame, which brings back 1.

Route 2 is therefore only worth its risk when the metamethod body is fully
traceable without exits; route 1 is the one that can win the benchmark, and its
cost is entirely on the semantics side. Both need the `lj_cont_tostr` result
check; route 1 in the continuation, route 2 in the guard.

## Red test for the gap

`tests/lib/ffrec-54.lua` with `tostring_mm_loop` and `tostring_mm_num_loop`
added to `loop_fns` (kept unregistered, since it is red until the above is
solved), `x86_64`, `-jon`:

```
FAIL loop 8 (function at line 97) did not compile to a root loop trace
FAIL loop 9 (function at line 105) did not compile to a root loop trace
ffrec-54 FAILED 2      (rc=1)
```

Their values are checked in both modes (`tostring-mm` 900, `tostring-mm-num`
600/900). No hot path changed on this branch, so the timings from the
predecessor note still stand: `b6_tostring.lua` `obj` case 2.4 ms traced before
`tostring54`, 182 ms now, `-joff` 149 ms.
