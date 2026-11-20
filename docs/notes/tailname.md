# Tail calls into C functions (P1.8b / tailname)

Branch `tailname2`, with the pre-push review fixes of branch `fable-batch3`.

## What is finished

The interpreter keeps the Lua caller frame for a tail call to a C function
(`ffid != 0`, fast function or C closure) and pushes an `LJ_CONT_TAILRET`
continuation frame above it (`BC_CALLT` in `vm_x64.dasc` and `vm_arm64.dasc`,
`NB = func_slot + 32`, args moved up by 16 bytes). The continuation makes the
caller return the C results, so the frame chain below the C function still
contains the caller and `lj_debug_funcname` resolves the name from the CALLT
site: `rep`/`move` instead of the loaded-module fallback `string.rep`/
`table.move`, and `__call` resolving to a C function names the object.
Tail calls to Lua functions keep the old frame replacement.

The trace recorder mirrors that frame layout, so traces keep compiling
`CALLT` into C/fast functions: the fast function is recorded inline exactly as
before, no bail-out. `docs/DIFFERENCES.md` records this as `FIXED`. A vararg
caller keeps its vararg frame too (see the rules below).

## The mechanism that broke with the stock recorder

The stock recorder (`lj_record_tailcall`) models a tail call as a frame
replacement: it moves func+args down to `J->base[-1-LJ_FR2]` and leaves
`J->base`/`J->baseslot`/`J->framedepth` unchanged. That is consistent with the
old VM, where the callee's base equals the caller's base, and it is still
what happens for a Lua callee.

With the kept caller frame the VM's `L->base` moves to the C frame
(`NB`), so the recorder's stack address mapping `base = L->base - J->baseslot`
is shifted by `NB - caller_base`. The first symptom is an assertion in
`rec_check_slots` (with `LUA_USE_ASSERT`):

    lj_record.c: slot 2 type mismatch: stack type 8 vs IR type 11
    (pc[-1]=148 baseslot=10 fd=1 maxslot=2 fsize=-1)

`fsize=-1` shows `J->pt == NULL`, i.e. the recorder is at the tail-called C
function's entry. In a release build the shifted mapping produces snapshots
whose slot addresses are wrong. On exit the restore writes tagged values over
the continuation frame's `[NB-32]`/`[NB-24]` slots, so when the C function
finally returns, `cont_dispatch` reads a garbage continuation value and jumps
to it. That is the `-jon` segfault seen in lpeg/penlight (`#1 lua_pcall`,
`cont_dispatch`'s `jmp *%rcx` with `rcx = 0xfff9...`, a tagged TValue).

## The fix

`rec_callt` (the recorder for `BC_CALLT`/`BC_CALLMT`) detects a callee that is
not a Lua function (directly or via `__call`) and builds the continuation
frame in the model with the same layout as the VM:

    [func+0] = cont value (KNUM with the LJ_CONT_TAILRET id)
    [func+1] = TREF_CONT          (the contpc slot)
    [func+2] = callee func
    [func+3] = TREF_FRAME
    [func+4..] = args

It shifts the func/frame/args block up by two slots, bumps
`J->base`/`J->baseslot` by `func+4` (so `base = L->base - baseslot` maps
correctly again) and adds 2 to `J->framedepth` (the continuation contributes a
`TREF_CONT` plus a `TREF_FRAME`, which `rec_check_slots` both count).

`lj_record_ret` handles the return into that frame: the generic continuation
pop already restores `framedepth`/`baseslot`/`base` to the caller frame, so
the `LJ_CONT_TAILRET` branch only rebases `rbase` to the pre-pop base,
sets `frame = frame_prevd(frame)` and jumps back to the return handling
(`retry_tailret`) to process the kept caller's own return.

The mapping error is worth recording because it is invisible in a release
build: only `rec_check_slots` catches the shift, and the release symptom is a
wild jump thousands of instructions later.

## Rules the model has to follow (found in the pre-push review)

Each of these was wrong in the first version and is pinned by
`tests/d54/err_08_tailcall_c_trace.lua`:

- **Only the bytecode tail call keeps the frame.** `lj_record_tailcall` has a
  second caller: `recff_metacall`, for a fast function that hands over to a
  metamethod (`tostring` -> `__tostring`, `pairs` -> `__pairs`). The VM does
  that through `vm_call_tail`, which replaces the frame of the fast function
  whatever the metamethod is. `lj_record_tailcall` therefore stays the plain
  frame replacement, and the continuation frame is built by `rec_callt` only.
  With the test in the shared function, `tostring(io.stdout)` in a hot loop
  (a C `__tostring`) crashed with the JIT on.
- **A Lua function can return through the continuation.** After
  `return tostring(obj)` with a Lua `__tostring`, the metamethod runs in the
  fast function's frame, whose link is the `LJ_CONT_TAILRET` frame. If the
  trace started in the function that made the tail call, that return leaves
  the trace. It has to end *before* the model pops the frames (link type
  "return to interpreter"), or the final snapshot pairs the metamethod's `RET`
  with the caller's base and the interpreter returns the wrong slots.
- **`__call` adds an argument.** `rec_call_setup` inserts the called object
  as the first argument; the block to move is given by `J->maxslot`, not by
  the `nargs` operand of the bytecode.
- **A vararg frame is kept as it is.** The VM tests the callee before it
  relocates `BASE` for a vararg caller, so the continuation frame sits on the
  vararg frame, the return goes through the ordinary vararg return
  (`BC_RETC_Z` on x64, `BC_RETM_Z` on arm64), and `debug.getlocal(1, n)`
  inside the C function reads the caller's real slots. The recorder does the
  same: no base relocation for a C callee, and `lj_record_ret` pops the vararg
  frame after the continuation.
- `baseadj` in `lj_record_ret` includes the popped continuation frame (the
  `__concat` remainder path computes the lower frame from it), and the
  kept-frame path has the same slot-limit check as `lj_record_call`.

## Measurements (x64, one pinned box, base 5d2e7883 vs head, interleaved, 7 runs)

Median wall time in ms; `tests/bench` classic set and a local call-heavy set:

    tostring loop   base 180.3   head 181.2
    new (constructor, setmetatable tail call)  base 27.6  head 27.5
    string.format wrapper   base 189.3  head 189.5
    select wrapper          base 0.94   head 0.94
    Lua->Lua tail recursion base 16.8   head 16.8
    b1_fnv   base 30.3  head 30.3
    b2_table64 base 3938 head 3878
    b2b_ms64 base 1127  head 1111
    b3_int32 base 47.7  head 47.7

Within noise; the constructor/format/select loops dropped from +28 %/+49 %/
+8000 % (the earlier bail-out version) back to parity.

## Gates (after merging main f51a7608, on the merged tree)

- `tests/harness.sh --strict --mode both --corpus tests/d54`: 173 pass,
  0 fail, 3 xfail (the pre-existing d54 divergences).
- `tests/ci-box.sh`: all stages passed on x64 and on arm64.
- `tests/ci-local.sh --sanitizers-only`: `ci-local: OK` on x64 and on arm64.
- corpus-ext lpeg and penlight: same in the `joff`, `jon` and `gcs` arms.
- The interleaved base/head benchmark above was repeated on the merged tree
  with the same result.

## Open for the next round

- A return hook for the Lua caller after the C function returns (PUC has
  one): the continuation returns without going through the hook dispatch.
  Recorded as `PENDING` in `docs/DIFFERENCES.md`.
- A function called through `pcall` that ends in a tail call to C
  (`pcall(function() return f_c() end)`) aborts the trace at the return
  (`NYI: return to lower frame`): the pcall frame below the kept caller is
  not resolved after the continuation pop. Correct, not compiled.
- Side exits inside a tail-called `pcall`/`xpcall` (frames: caller,
  continuation, pcall, callee) are exercised by `err_04_tailcall_c`,
  `err_08_tailcall_c_trace` and the corpus-ext programs; there is no
  generator that enumerates exit positions.
- Error names raised from compiled code: checked by modes A/B on the d54
  corpus (they match `-joff`); the boundary is not proven exhaustively.
- `debug.setlocal` on a `(*temporary)` slot of the kept caller can overwrite
  the continuation slots, like it can for every metamethod continuation
  frame in stock LuaJIT.
- Other interpreter backends (x86, ppc, mips) are not ported; only x64 GC64
  and arm64. The recorder's kept-frame path is compiled for those two only.
- The continuation frame stores the cont id at `[NB-32]`; any future
  continuation id must not collide (0 = tailcall, 1 = ffi callback,
  2 = tailret).
- The unrelated `istailcall` item that `docs/DIFFERENCES.md` still listed when
  this note was written is fixed since (`83e0121d`, docs `8a50a0f9`, merged
  `35854613`); it moved to `docs/CHANGELOG-VM.md` and its mechanism is in
  `docs/notes/istailcall.md`. The return-hook item above, this note's own open
  point, is still `PENDING` in `docs/DIFFERENCES.md`.
