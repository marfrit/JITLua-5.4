# Bug dossier — x64 JIT math.random statistics crash/hang

Status: known bug, **no VM fix** (Fable/VM owner). Recorded as known-bad math B.

## Repro and fail rate

`tests/lib/math-jit-repro.lua` (2.1-compatible): one `aux` loop called with
`aux(1,32)`, `aux(1,33)`, `aux(-10,10)`. On x64-box under `-jon`:
13/20 failures (SIGSEGV ~0.02 s or hang >40 s; RSS stays <7 MiB), `-joff`
passes. Failures are seed/timing dependent, not OOM.

## Interpreter vs JIT, opt levels

`-joff` passes. `-jon -O0/-O1/-O2/-O3`: intermittent SIGSEGV/hang in all
levels (e.g. `-O0` 3/5 SIGSEGV, `-O2` 4/5 SIGSEGV in one 5-run batch). JIT is
required for the failure.

## First bad commit

`git bisect` on x64-box with a clean build per commit (2.1-compatible repro,
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
