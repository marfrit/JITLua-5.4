# Second opinion from His on ADR-001 (int64 value model), 2026-11-15

This is advice, not a decision. ADR changes are Markus's call: put the choice to him together with this note.

## Short answer

LuaJIT's own design keeps `TValue` at 8 bytes. A value that doesn't fit in a slot goes behind a pointer, which is
how 64-bit FFI integers already work. I would **not** start the 16-byte `TValue`.

Instead, reopen the option ADR-001 rejected, "box large ints in a GC object", in its **interned** form. Spike it
before deciding.

Fleet precedent: there is no 16-byte-value LuaJIT branch or patch anywhere in the fleet. Deferring int64 entirely
also doesn't fit: MISSION §2 goal 1 requires the int/float model. Deferring as staging is fine, and that is what you
already do.

## Why not 16 bytes (beyond the ADR's own risk note)

1. **It is not mechanical.** "8" means slot size, pointer size and frame-link size at the same time:
   - GC64 uses two-slot frame headers (`LJ_FR2`).
   - The JIT backends hardcode slot offsets in SLOAD and stack restore (`lj_asm_*.h`).
   - Snapshots and trace exits depend on it (`ExitState`, `lj_snap_restore`).
   - So do table array parts, the hash `Node` layout, upvalues, FFI conversions and seven interpreters.

   Each site needs a "slot or pointer?" decision, and the harness only catches the sites it exercises.
2. **It costs every program.** Every stack slot and every table value doubles in memory and cache footprint, to
   serve values most programs never produce (|n| ≥ 2^31). That contradicts MISSION §3: no silent deoptimisation
   beyond what the int/float model forces.
3. **It breaks your own "keep the tree buildable" order.** Step 1 (16-byte TValue) breaks every VM at once, and
   nothing runs again until step 3 has landed for that backend.

## Boxed, interned int64: what I would spike

- **int32 stays the inline fast path (dual-number).**
  - arm64 is natively `LJ_NUMMODE_DUAL`.
  - x64 is single-number by default and needs `LUAJIT_NUMMODE=2` for the int/float split. **Check that the born
    x64 build really uses it**, or the x64 harness tests a different number model than arm64.
- **Representation:** an integer outside int32 becomes an immutable GC object holding an `int64_t`. It is interned
  in a hash like strings, so pointer equality means value equality. Raw equality, table keys and the existing
  same-type GC-pointer comparisons then stay correct without new compare code on the fast paths.
- **Interpreter fast paths:** they only change where int32 arithmetic overflows. Today that branch converts to a
  double. Instead it goes to a C slow path (`lj_meta_arith` or a new `lj_int64` helper), which returns the box.
  That is a handful of overflow exits per backend, not every slot access.
- **C side:** `math.type`, `tostring`, `string.format('%d')`, comparisons, and 5.4 table-key normalisation
  (float keys with an integral value become int keys).
- **JIT, step one:** the recorder treats boxed ints as NYI. The trace aborts and the interpreter runs the code,
  which stays correct.
- **JIT, later:** lower boxed ints to `IRT_I64` and reuse the allocation sinking that already removes boxes for
  64-bit FFI cdata (`lj_opt_sink.c`, `lj_crecord.c`). That machinery exists for exactly this case: a 64-bit integer
  behind a pointer.
- **Cost:** one allocation whenever a value leaves int32, as in hashing, 64-bit masks and counters. It is always
  correct, and slower on that code until the JIT sinks the boxes.
- **Open point:** the tag. Either a free internal itype, or cdata with a dedicated CTID. Check the tag space in
  `lj_obj.h` (around `LJ_TNUMX` / `LJ_TISNUM`) before you choose.

## Migration order for the boxed variant (green after each step)

1. GC type, intern table, accessors and the C semantics (tostring, tonumber, math.type, comparisons,
   table-key normalisation, `%d`). Only C helpers reach them so far, so no test changes.
2. Lexer and parser:
   - integer constants beyond int32 become boxed constants (KGC);
   - `//` parses and BC_IDIV runs through the C helper first;
   - dump format with EXTRAARG.
3. VM per backend, arm64 first, then x64 with NUMMODE=2:
   - the overflow exits of ADD/SUB/MUL/UNM, the bitwise ops, IDIV and MOD go to the C helper;
   - the arith dispatch accepts the boxed tag as a number (a vmeta fallback is fine at first).
4. JIT: the recorder aborts on boxed ints (NYI). Correctness is kept.
5. Later: `IRT_I64` lowering and sinking, i.e. performance.

## Decision rule

Spike steps 1-3 on arm64 against `numeric_01_types.lua` (maxinteger), `numeric_03_idiv.lua` (`//`) and
`bits_01_ops.lua` (64-bit shifts). Build and test with `arm-box` only.

- If it lands green without touching slot code: write it up as ADR-001b and keep 16 bytes as the documented
  fallback.
- If the boxed path forces changes into every arithmetic fast path: go back to 16 bytes, with the measured diff as
  evidence.

Either way, Markus decides on the ADR.

Intercom: the broker was full (128 sessions, all held by pi-web's session daemon). His raised the cap and
restarted the broker at 10:2x. `ask claude` should work again; if it doesn't, write a file like this one. Never
kill or start the broker or the bridge yourself.

## Addendum (Markus, 10:31): does boxing break the JIT? Measure it in the spike.

Markus's concern: with boxed int64, does everything outside int32 turn into an exception path and ruin the JIT?
My view:
- Hot int32 code is unaffected. It already has overflow guards, and only the overflow target changes from a
  double to a box.
- 64-bit code (hashes, PRNGs, 64-bit masks, ms/ns timestamps) is ruined while the recorder only aborts on boxed
  ints (step 4).
- It is fine once step 5 keeps int64 unboxed in registers and sinks the boxes. That is how FFI `uint64_t` loops
  run with zero allocations today.
- The residual cost is big ints stored in memory: tables of 64-bit values, where every element is a box plus an
  intern lookup.

So **step 5 is part of acceptance, not "later"**. Add a benchmark gate to the spike so the ADR rests on numbers.

- **B1 FNV-1a-64** over a long string (e.g. 10 MB, built in-script): a register-resident 64-bit loop.
- **B2 table of 1e6 64-bit values:** fill with an LCG/xorshift64, read and sum, `table.sort`.
- **B3 int32 control:** the same loops staying in int32 range, to show the normal case did not regress.

Run each benchmark on four arms:
1. our build with JIT on;
2. our build with `-joff`;
3. **stock LuaJIT v2.1** with FFI `uint64_t` / `0ULL` literals as the yardstick: build it from the `upstream`
   remote, e.g. `git archive v2.1 | (mkdir -p /tmp/stock && tar x -C /tmp/stock)`, then `arm-box` there;
4. PUC-Lua 5.4.7 (`tests/ref/bin/lua54ref`).

Method:
- Run all arms inside the **same** arm-box job: same box, same moment. Repeat 3×, report the median wall time,
  and for our build also allocation counts (`collectgarbage("count")` before/after).
- escher shares its CPU with model serving, so treat differences under ~10 % as noise.

Write the table into the ADR (ADR-001b, or the 16-byte fallback).

What would favour 16 bytes:
- B1 with JIT on does not reach the FFI yardstick within ~1.5× after step 5;
- or B2 allocates per element and is slower than PUC-Lua.

B3 must not regress against today's main.

## Addendum 2 (Markus, 11:47): prior art from CogVM/Spur, widen the immediate range

Spur, the memory model of Squeak/Pharo's Cog VM, solved exactly this problem:
- SmallIntegers up to 61 bits live inside the tagged 64-bit word, and the Cog JIT does their arithmetic inline
  with an overflow check;
- only beyond that does it fall back to LargeInteger heap objects.

That is the boxed model proposed above. The lesson: **make the unboxed range as wide as the tag scheme allows**,
not as wide as is convenient.

For LuaJIT GC64:
- **The idea:** a TValue carries a 47-bit payload under the 17-bit itag. Integers could live inline up to signed
  47 bits instead of int32, and only true 64-bit values would be boxed.
- **What 47 bits cover:** ms timestamps (~41 bits), file offsets, almost every counter.
- **What still boxes:** hashes, 64-bit masks, PRNG state.
- **Cost:** the overflow check moves from the native 32-bit overflow flag to a 64-bit op plus a 47-bit range check
  (sign-extend and compare), so the VM fast paths and the JIT's integer guards change. Non-GC64 targets would
  stay int32.

**Not part of the spike.** First prove that boxing works at all (steps 1-3 plus the benchmark gate). Record
"47-bit immediates" in the ADR as a documented refinement (step 6). Benchmark B2 (a table of 64-bit values) and a
variant with ms-timestamp-sized values (~2^41) show what it would buy. Decide after measuring.

Coroutines: no prior art needed. LuaJIT 2.1 already yields across pcall and metamethods. The 5.4 delta is
`coroutine.close` together with `<close>` variables, i.e. cleanup on abort: diligent work, not architecture.
