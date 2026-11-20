# Recording `tostring(obj)` again — measurement and the open ticket (branch `tostringrec`)

Task: `tostring54` (now on main) made a `__tostring` result check correct by
having the recorder leave every `tostring` call that has a metamethod to the
interpreter (`recff_tostring`, `src/lj_ffrecord.c`). The price, from
`tests/bench/b6_tostring.lua` on x86_64 (N = 2M, medians): the `obj` case
(`tostring(o)` where `o.__tostring` returns a string) is **2.4 ms traced before,
182 ms now**; `-joff` is 149 ms. Goal was to record the call again with a guard
on the result type. This note records what was measured and why the cheap
version does not work; the tests that pin the semantics are in this branch.

## Semantics are safe today (tests, both modes)

`tests/d54/tostring_07_hot_bad.lua` (new) — identical output with `-joff` and
`-jon`, and mode A agrees with PUC 5.4.9:

```
late-bad	false	'__tostring' must return a string	calls	1000
late-bad-bool	false	'__tostring' must return a string	calls	1200
num-result	33000	123456789012345	2.5	-0.0	integer
field-result	3001	false	'__tostring' must return a string
mm-raises	false	boom
```

The metamethod returns a string for the first 999/1199 calls (so the loop runs
hot) and a table/boolean after that: the error arrives at exactly the right
call count. A legal number result converts with the 5.4 number format; a result
read from a table field (type unknown to the trace) raises; an error raised
inside the metamethod is reported as that error, not as the result-check error.
`tests/lib/ffrec-54.lua` gains the two `__tostring` loops with their value
checks (`tostring-mm` 900, `tostring-mm-num` 600/900), green in `-joff` and
`-jon`; they are deliberately **not** in `loop_fns` (which asserts a root loop
trace) — that is the open gap below.

## What was tried, and what the probe shows

Recorder-side attempt: `recff_tostring` records the `__tostring` lookup with
guards (`lj_record_mm_lookup`, which is also what makes a method added later
end the trace), then builds a `lj_cont_ra` continuation frame in the IR slots
exactly like `rec_mm_prep` and records the call with `lj_record_call`;
`lj_record_ret`'s `lj_cont_ra` branch validates the result TRef through a new
`rec_tostrres` (string passes, int64/number convert as the interpreter does,
anything else — including a result whose type the trace cannot know — aborts the
trace so the interpreter raises). A `jit_State.tostrarm` flag arms the guard;
`rec_mm_prep` refuses a second `lj_cont_ra` frame while it is armed, so the
one-deep arm cannot be handed the wrong result.

Values stayed correct in every test above, but the trace never compiled:

```
[TRACE --- t1.lua:3 -- NYI: return to lower frame at t1.lua:1]   (LJ_TRERR_NYIRETL)
```

Why: `lj_record_ret` walks the **real Lua stack** (`frame = J->L->base - 1`),
and the continuation frame the recorder built exists only in the IR slots — the
interpreter never created it, because the 5.4 C fast function calls the
metamethod with a normal `lua_call` instead of tail-calling it. The frame walk
therefore reaches the fast function's C frame and hits
`lj_trace_err(J, LJ_TRERR_NYIRETL)  /* NYI: handle return to C frame */`.

The pre-`tostring54` speed came from a different mechanism, measured on
`f8c70a23` with a probe in `lj_record_ret`:

```
PROBE entry: framedepth=1 ispcall=0 iscont=0 islua=1
[TRACE   1 t1.lua:3 loop]
obj -jon 0.0 ms
```

The old `recff_tostring` **tail-called** the metamethod, the *interpreter* then
replaced the fast function's frame with the metamethod's Lua frame, and the
hotcount started inside the metamethod with a chain of Lua frames below it — so
`lj_record_ret` was entered with a Lua frame (`islua=1`) and the loop linked
back to itself. LuaJIT's normal metamethod recording (`rec_mm_len`,
`rec_mm_callcomp`) works the same way: the *interpreter* creates the
continuation frame before the recorder follows. A fast function cannot get that
frame by describing it to the recorder alone.

## Open ticket: what it would take

1. Build the continuation frame **physically** on the Lua stack, the way
   `recff_stitch` does in the same file (`memmove` the `TValue`s,
   `setframe_ftsz(..., FRAME_CONT)`, `setcont`, `setframe_pc`), and keep the IR
   slots in step. `recff_stitch` is the only existing precedent for a frame the
   recorder invents; it also shows the cleanup that is needed if the recording
   then aborts.
2. Teach `lj_record_ret`'s frame walk to step over that frame: its loop is
   `while (frame_ispcall(frame))`, and a `FRAME_CONT` frame is not a pcall
   frame, so today the walk stops and reports "return to C frame".
3. Only then does the `rec_tostrres` result guard in this branch's design apply;
   the guard code itself (string passes, number converts, anything else aborts
   so the interpreter raises, one-deep arm refused by `rec_mm_prep`) is written
   and can be re-used.
4. Re-measure `b6_tostring.lua` (base `945075d2` vs head, one box job,
   interleaved): the `obj` case at `-jon` should come back from 182 ms towards
   the pre-`tostring54` 2.4 ms, and `tests/lib/ffrec-54.lua` should then get the
   two loops registered in `loop_fns`.

`tostring(cdata)` (item (a) of the brief) is part of the same shape: its
per-type base metatable has a **C** `__tostring` (`ffi_meta___tostring`), which
the recorder cannot inline as a Lua call, so it keeps leaving the trace; output
is unchanged. `tostring54`'s risk 1 (a `__tostring` added later to the
string/number base metatable) is already closed on this base by
`recff_has_tostring()` recording the lookup with guards.

## Gate on this branch (tests and docs only, src unchanged from `945075d2`)

`sh tests/ci-box.sh`: see the DONE report for both boxes.
