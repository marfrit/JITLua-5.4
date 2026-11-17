# Bug dossier — arm64 bit.* shifts return 0

Status: known bug, **no VM fix** (Fable/VM owner). Not asserted in the portable
ffi_int tests; this dossier is the handover.

## Repro and fail rate

`tests/lib/bit-shift-repro.lua` (stock LuaJIT 2.1 API; INT32_MIN computed as
`-2147483647-1`). On arm-box it exits 1 with:

```
shift-ok false 0 0 0 0 0 0 0 0LL false
```

All `bit.lshift/rshift/arshift/rol/ror` return **0** for native integers and
cdata. Fail rate 10/10 on arm64; x64-box 10/10 passes (`lshift(1,31)` ->
-2147483648, cdata lshift 63 -> -9223372036854775808LL).

## Interpreter vs JIT, opt levels

- `-joff`: fails (top-level calls). `-jon`: fails identically at top level.
- `-jon -O0/-O1/-O2/-O3`: all fail identically for top-level calls.
- Inside a hot loop the JIT trace is **correct**: a loop
  `for i=1,1000 do s=bit.lshift(1,i%31) end` prints the correct 256 under
  `-jon`; `-joff` remains 0. The fast-function asm path is the defective path;
  once a trace covers the shift it uses the VM BSHL IR and is right.
- `-jdump=+rsi` therefore shows a *good* trace, not a bad one:
  `tests/lib/bit-shift-trace.lua` produces TRACE 1 with `int BSHL` IR and
  correct mcode. There is no bad trace to dump; this is a fast-function bug,
  not a recorder bug.

## First bad commit

`git bisect` on arm-box (clean build per commit, repro above):
**first bad commit `cb2f6da23b5cf88668718f6a79cf7e95143e4c08`**
"Phase 1 (ADR-001b step 6 sub-step 1b): VM checkint range test on arm64 + x64".
Parent `63c8f1a9` (LuaJIT 2.1 base) passes; the fork tree at `27de9ae`,
`c3e739b`, `e76a680`, `844188b` still passes; `cb2f6da` fails and every later
tested commit fails. The bisect range was 63c8f1a9..73b2a2cb.

## Hypothesis (one line)

`cb2f6da` added the widened-range test inside the arm64 `checkint` macro, which
uses **TMP0 as scratch** (`ubfx TMP0, reg, #32, #15; cbnz TMP0`); the bit-shift
fast-function macro `.ffunc_bit_sh` stores the left operand in TMP0 before
calling `checkint` on the shift count, so TMP0 is clobbered and the shift
instruction sees x=0 (`src/vm_arm64.dasc:293-299` checkint,
`src/vm_arm64.dasc:1869-1893` .ffunc_bit_sh). Correct fix requires a VM/dasc
register change (move x to a non-scratch register or check the count before
loading x), so it is not done here.

## Touch points

- `src/vm_arm64.dasc` `.ffunc_bit_sh` and `checkint` macro.
- Portable coverage: `tests/d54/ffi_int_03_bit.lua` asserts band/bor/bxor/
  bnot/tobit/tohex but deliberately not shifts; `docs/ffi-int-semantics.md`
  records the arm64 failure.
- Repro/trace helpers: `tests/lib/bit-shift-repro.lua`,
  `tests/lib/bit-shift-trace.lua`.
