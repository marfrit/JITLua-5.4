# Bug dossier — x64 JIT math.random statistics crash/hang

Status: **FIXED** on `jit-math-random` (Fable/VM owner), both-box gates green.
Kept for traceability; `tests/lib/math-random-jit.lua` is the ci-box
regression (`-joff`, `-O0`, `-O3`). Known-bad math B row removed.

## Root cause

Not the key representation or the hash: an x64 register-width bug in the
backend, the same family as `adc0eb97` (snapshot restore).

- `src/lj_asm_x86.h` `asm_conv`, checked narrowing `int64 -> int32`
  (`IRCONV_INT_I64|IRCONV_CHECK`, emitted by `recff_math_random` when both
  bounds fit int32): executed `movsxd dest, left32; cmp dest, left; jne exit`
  and left the **sign extension** in `dest`. Every other producer of an
  `IRT_INT` register on x64 zero-extends (32-bit ops clear the upper half),
  and the backend relies on that invariant.
- Consumers that OR the type tag into the full register:
  `asm_href` (`mov tmp, LJ_TISNUM<<47; or tmp, key` -- comment even said
  "an int32 key register is zero-extended") and `asm_tvptr`'s GC64 path
  (`or tmp, src` for the `cTValue *key` passed to `lj_tab_newkey`). The
  unchecked `int32 -> int64` zero extension (`ra_left` no-op) is a third,
  latent one.
- With a negative key the upper 32 bits are all ones, so the OR yields
  `0xFFFF...` (itype 0x1FFFF = nil-ish garbage) instead of
  `(LJ_TISNUM<<47)|(uint32)k`. The inline HREF never matches the node the
  interpreter stored, the trace takes the NEWREF path, and `lj_tab_newkey`
  inserts a node under the garbage key. Later `hashkey()` on that node's key
  disagrees with the position it was inserted at, so the collision-chain
  walk at `lj_tab_newkey:519` reads past the chain (SIGSEGV) or never finds
  its predecessor (hang). The randomness came from which negative key
  collided first; `aux(1,32)`/`aux(1,33)` were never the trigger.

Measured on x64-build before the fix (20 runs each, -O3): `math-jit-repro.lua`
17/20, `-O0` 20/20; `aux(1,32)` only 0/20; `aux(-10,10)` only 7/20;
`aux(-40,-1)` only 20/20. After: 0/50 at -O0 and -O3, 0/20 on both negative
ranges.

Why arm64 never showed it: its checked CONV ends with `mov w_dest, w_left`
(zero-extending) and `asm_tvstore64` adds the key with an explicit `UXTW`;
both the producer and the consumer are width-correct there.

## Fix

- `asm_conv`: re-materialize the result with a 32-bit `mov dest, left`
  after the guard, so the invariant holds for every consumer (HREF, NEWREF,
  snapshot restore, zero-extending CONV).
- `asm_tvptr` (GC64): an int32 key is written as two 32-bit stores
  (`mov [tmptv+4], LJ_TISNUM<<15; mov [tmptv], src`), like ASTORE/HSTORE and
  the snapshot restore, so the NEWREF key never depends on the register's
  upper half. The CONV fix alone is sufficient (measured); the store change
  removes a scratch register and the 64-bit immediate load.

The first-bad commit `ad283709` only exposed the bug: it made `math.random`
recordable, which produced the first checked `I64->INT` CONV whose result
is used as a hash key in a trace. The dossier's key-representation
hypothesis was wrong.


## Repro and fail rate

`tests/lib/math-jit-repro.lua` (2.1-compatible): one `aux` loop called with
`aux(1,32)`, `aux(1,33)`, `aux(-10,10)`. On x64-build under `-jon`:
13/20 failures (SIGSEGV ~0.02 s or hang >40 s; RSS stays <7 MiB), `-joff`
passes. Failures are seed/timing dependent, not OOM.

## Interpreter vs JIT, opt levels

`-joff` passes. `-jon -O0/-O1/-O2/-O3`: intermittent SIGSEGV/hang in all
levels (e.g. `-O0` 3/5 SIGSEGV, `-O2` 4/5 SIGSEGV in one 5-run batch). JIT is
required for the failure.

## First bad commit

`git bisect` on x64-build with a clean build per commit (2.1-compatible repro,
fail threshold >=3/20): first **logical** bad change
`ad28370970dc96be44abafff0511a24119af7067`
"JIT: math.random on the 5.4 xoshiro state (same sequence as the interpreter);
widened-int fixes in numberVnum/lua_tointeger(x); math.modf pushes integers;
C API box test anchors its box". Parent `cc168014` passes. `ad283709` itself
does not build in isolation (math.modf dispatch-table mismatch); the next
build-repair `fcc6df4d` builds and still fails 15/20, so `ad283709` is the
logical regression and `fcc6df4d` only the build fix.

## Evidence

- Crash RIP (`-jdump=+rsi` run, debug core parsed): `lj_tab_newkey:519`
  (`while (noderef(collide->next) != n)`) after a JIT table store.
- `-jdump=+rsi` last live trace: TRACE 4, `CALL` / `assert` / TGETV / TSETV /
  JLOOP with an explicit `lj_tab_newkey` call in mcode; the mcode post-call
  chain write is what crashes. The trace dump is in the Session48 notes and was
  reproduced from `tests/lib/math-jit-repro.lua`.
- Hypothesis (one line): the math.random recorder/xoshiro change makes the
  recorded table-key path and `lj_tab_newkey` disagree about the key
  representation/hash, so the collision-chain walk reads a corrupt `next`
  pointer after a JIT table store; Fable should compare the recorder's
  random-result key type with the interpreter's int64 key path.

## Touch points

- `src/lj_ffrecord.c` (math.random recorder), `src/lj_carith.c` / random
  implementation, `src/lj_tab.c` `lj_tab_newkey`/hashkey.
- Repro: `tests/lib/math-jit-repro.lua`; known-bad math B;
  `docs/phase0-status.md` Session48.
