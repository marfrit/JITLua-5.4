# cstack.lua gsub block: the C-call bound is missing (known-bad)

Triage 2026-11-20 (batch 7, cstack.lua). Status: real defect, **deferred** —
needs VM assembly work on both backends, see design below. Tracked by the
`tests/corpus/puc54/cstack.lua` row in `tests/known-bad.tsv`; the file stays a
documented skip row in `tests/t-guarded.tsv` (a signal death is a hard FAIL the
XFAIL machinery cannot cover).

## Repro

```lua
local count = 0
local function foo ()
  count = count + 1
  string.gsub("a", ".", foo)
end
local ok, err = pcall(foo)
print("ok:", ok, "err:", tostring(err), "count:", count)
```

PUC 5.4.9: `ok: false  err: <file>:<line>: C stack overflow  count: 197`.
This tree (933cfe09 and later): **SIGSEGV** in both JIT arms, x86_64 and
arm64. The second gsub variant in the suite (`setmetatable({},
{__index = foo})`, replacement looked up through `__index`) dies the same
way (PUC count 99).

## What PUC does

`luaD_call`/`ccall` (ldo.c) counts *every* call through the C boundary into
`L->nCcalls` and decrements on return; `luaE_checkcstack` (lstate.c) raises a
recoverable "C stack overflow" at `LUAI_MAXCCALLS` (200 in 5.4.9) and
"error in error handling" if the handling itself overflows the budget
(`>= MAX*11/10`). The gsub ping-pong `foo -> gsub(C) -> foo -> gsub(C) ...`
hits the bound at ~197 cycles and unwinds cleanly. PUC additionally bounds
the pattern matcher's own C recursion with `matchdepth` (lstrlib.c, also 200,
"pattern too complex"); this tree already has that guard
(`match` in `src/lib_string.c`, `LJ_MAX_XLEVEL`), which is why the suite's
pattern block passes here.

## Where this tree stands

`L->ccallnest` (`src/lj_obj.h`) counts **pcall/xpcall frames and
coroutine resume/close** only, bounded by `LJ_MAX_XLEVEL` (200), incremented
in the x64/arm64 fast paths and the `lib_base.c` fallbacks, counted out in
`vm_returnp` (see the design comment at `lj_state.c:297` and
`lj_ffrecord.c:633`). Plain C<->Lua ping-pongs never touch it:

- Lua -> C: the VM CALL path in `vm_*.dasc` calls the C function directly;
  nothing is counted.
- C -> Lua: C library functions enter the VM through the `lj_vm_call`
  trampoline (assembly in `vm_*.dasc`); nothing is counted.
- JIT-compiled code calling C functions emits a direct call
  (`lj_emit_*.h`); nothing is counted.

So the recursion runs until the real C stack overflows: SIGSEGV.

## Design for the fix (when it is picked up)

Add a separate counter `L->ccstack` (do **not** reuse `ccallnest`: its exact
bookkeeping is tested by `tests/d54/err_04_ccall_bound.lua` and it is scoped
to protected calls) mirroring PUC's `nCcalls`:

1. Increment + bound check at every Lua->C entry:
   - interpreter: the C-function call site of the CALL opcode (and the
     vararg/tail-call C sites) in `vm_x86.dasc`, `vm_x64.dasc`,
     `vm_arm.dasc`, `vm_arm64.dasc`, with the decrement at the C-return
     continuation in the same files;
   - JIT: emit the inc/dec around C calls in `lj_emit_x86.h` and
     `lj_emit_arm64.h` (the recorded direct calls and the `lj_ccallback`
     entry), including the trace-abort unwind path.
2. Increment + bound check at every C->Lua entry: the C side of the
   `lj_vm_call` trampoline (the C function's call is synchronous in LuaJIT,
   so the inc/dec can be paired in the C wrapper around the trampoline) and
   the C API call path (`lj_api.c`).
3. Bound semantics like `luaE_checkcstack`: raise "C stack overflow"
   (recoverable, `LJ_ERR_CSTKOV`) exactly at the bound; "error in error
   handling" when the bound is exceeded *while handling* (status
   `LUA_ERRERR`), which the existing `lj_err_stkov`/`lj_err_mem` checks
   already route through `lj_err_err`.
4. Coroutine creation must snapshot the bound the way `ccallnest` does
   (`ccallbase`), so a resumed coroutine inherits the caller's depth.

Acceptance: the two suite gsub blocks end in "C stack overflow" with PUC-like
counts (~197/~99), `tests/d54/err_11_errerr_msg.lua` and
`tests/d54/err_04_ccall_bound.lua` stay green, and `cstack.lua` runs to `OK`
in all arms on both architectures — then flip its row to `run` in
`tests/t-guarded.tsv` and drop the known-bad row.

## Also observed (not tracked here)

`pcall(loop)` on a plain (handler-less) overflow gives PUC's
`<file>:<line>: stack overflow` (location prefixed, both -jon and PUC) but
the interpreter drops the prefix (the overflow detection replaces the
violating frame with a dummy before `lj_debug_addloc_rt` can find a line).
The suite's cstack.lua does not observe this; left for whoever takes the
message-formatting pass.
