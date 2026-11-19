# Tail calls into C functions (P1.8b / tailname)

Worktree `LuaJIT-5.4-tailname2`, branch `tailname2`.

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
before, no bail-out. `docs/DIFFERENCES.md` records this as `FIXED`.

## The mechanism that broke with the stock recorder

The stock recorder (`lj_record_tailcall`) models a tail call as a frame
replacement: it moves func+args down to `J->base[-1-LJ_FR2]` and leaves
`J->base`/`J->baseslot`/`J->framedepth` unchanged. That is consistent with the
old VM, where the callee's base equals the caller's base.

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

`lj_record_tailcall` detects a C callee (directly or via `__call`) and builds
the continuation frame in the model with the same layout as the VM:

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
the new `LJ_CONT_TAILRET` branch only rebases `rbase` to the pre-pop base,
sets `frame = frame_prevd(frame)` and jumps back to the Lua-return handling
(`retry_tailret`) to process the kept caller's own return.

The mapping error is worth recording because it is invisible in a release
build: only `rec_check_slots` catches the shift, and the release symptom is a
wild jump thousands of instructions later.

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

- Recorder correctness for a trace that *exits inside* a tail-called C
  function is only exercised by tests and lpeg/penlight; the frame model is
  mirrored but a targeted side-exit test inside a tail-called C function is
  not part of the suite yet.
- Error names raised from compiled code: checked by modes A/B on the d54
  corpus (they match `-joff`); no case has been found where a compiled error
  path differs, but the boundary is not proven exhaustively.
- Other interpreter backends (x86, ppc, mips) are not ported; only x64 GC64
  and arm64.
- The continuation frame stores the cont id at `[NB-32]`; any future
  continuation id must not collide (0 = tailcall, 1 = ffi callback,
  2 = tailret).
- `docs/DIFFERENCES.md` still lists the unrelated `istailcall` PENDING item.
