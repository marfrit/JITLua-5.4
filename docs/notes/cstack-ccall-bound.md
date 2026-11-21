# cstack.lua gsub block: the C-call bound for calls from C

Triage 2026-11-20 (batch 7, cstack.lua); fixed 2026-11-20 on branch
ccallbound. `tests/corpus/puc54/cstack.lua` runs in the corpus
(`tests/t-guarded.tsv`), the known-bad row is gone, the changelog entry is in
`docs/CHANGELOG-VM.md` ("C-call bound for every call from C into the VM").
The sections up to "Design as first planned" describe the defect as it was
found; "What was built" is the design that went in, and it is not the planned
one.

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

## Design as first planned (not built)

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

## What was built

One counter, C code only, no assembly and no JIT change.

- **The same counter.** PUC has one `nCcalls` for pcall, resume and every
  other C call, and a pcall level and a gsub level have to add up against the
  same 200 (cstack.lua's second block: 99 cycles of two levels each). A
  second counter would have bounded each kind at 200 on its own. So
  `L->ccallnest` takes the new levels too; the pcall/xpcall fast paths, the
  resume paths and the recorder (`lj_record_ccallnest`) are unchanged.
- **Counted at the C-side entries into the VM**, not at the Lua -> C call
  sites. In PUC a call from Lua to a C function does not count either
  (`luaD_precall`/`precallC`); what counts is `luaD_call`, the way from C
  back into the VM. Here that is `lj_vm_call` and `lj_vm_pcall`, which only C
  code calls: `api_vm_call` in `lj_api.c` (lua_call and the 12 metamethod
  call sites of the API), `lua_pcall`, `lua_cpcall`, `lj_meta_tbccloseall`
  (`__close` from C), `gc_call_finalizer`, `lj_err_run` (message handler),
  `lj_vmevent_call`. The interpreter's CALL path, the fast functions and the
  compiled code never get there, so nothing hot changes.
- **Check as in `luaE_checkcstack`** (`lj_err_ccallover`/`lj_err_ccall`):
  refused at the bound with "C stack overflow", allowed in the 20 levels
  above it (they are only reachable while that error is handled), refused
  with "error in error handling" from 220 on. The checks here look at the
  count before the increment, PUC after it, so the main thread starts at 1
  (`LJ_CCALLNEST_BASE`) for the same number of usable levels. The former
  stand-in of 3 stood for the `lua_cpcall` and `lua_pcall` of the standalone
  executable, which count themselves now.
- **Counting out.** A normal return restores the value the caller saved. An
  error has no C code to run in the frames it skips, so `err_unwind` takes
  one level off for every frame entered from C that it unwinds: `FRAME_C`
  (lj_vm_call) and a catching `FRAME_CP` (lj_vm_pcall). That is the reason
  every caller of the two has to count, `lj_vmevent_call` included. The
  pcall/xpcall frames count out in `lj_vm_unwind_ff`, as before.
- **`__close` handlers during an unwinding** get the nesting of the catching
  frame (`tbc_catchlevel`), like PUC, which has longjmp'ed to the catcher
  before it calls them. Under a `pcall`/`xpcall` called from Lua they run
  from the VM after the landing pad (`vm_tbcerr`, `lj_meta_tbcerr`), with no
  C frame of the throw left, and the pcall is counted out only when the
  last handler is done; nothing below applies to them. Under a protected
  call from C they run from `err_unwind`, with every C frame
  of the throw still on the C stack below them. With the catcher's count
  alone, a handler that recurses to the bound, fails and thereby starts the
  handlers of its own frames would add up to 200 C levels per round, without
  end. So `L->ccallthrow` remembers the count at the throw, `g->ccallslack`
  sums up how much deeper the C stack is than the count says, and
  `lj_meta_tbccloseall_at` refuses handlers once that is above 220. One round
  always fits; the C stack stays within about twice the bound. The unwinder
  passes the catcher's count as an argument and `L->ccallnest` changes only
  around each handler call, because closing can raise an error itself (no
  Lua stack left for a handler) and must not leave a lowered count behind.
- **`lj_meta_tbccloseall` counts its handler calls itself.** The call sites
  that close another thread (`coroutine.close`, `lua_closethread`, the wrap
  error path) used to hand over the closer's count + 1 to stand for that
  call; they hand over the closer's count now.

Not done, see `docs/DIFFERENCES.md`: metamethods called by the interpreter
are not C calls here; pcall/xpcall cannot use the 20 extra levels;
`collectgarbage()` inside a finalizer nests (bounded now); FFI callbacks are
not counted.

## Also observed (not tracked here)

`pcall(loop)` on a plain (handler-less) overflow gives PUC's
`<file>:<line>: stack overflow` (location prefixed, both -jon and PUC) but
the interpreter drops the prefix (the overflow detection replaces the
violating frame with a dummy before `lj_debug_addloc_rt` can find a line).
The suite's cstack.lua does not observe this; left for whoever takes the
message-formatting pass.
