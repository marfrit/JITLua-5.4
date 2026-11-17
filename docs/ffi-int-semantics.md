# FFI int64_t / uint64_t and bit semantics — intended behavior

Library/interpreter-level reference for this fork. No VM/dasc/recorder/lj_meta
changes are part of this item. Tests: `tests/d54/ffi_int_01_arith.lua`,
`ffi_int_02_convert.lua`, `ffi_int_03_bit.lua` (modes B,R; PUC 5.4 has no ffi,
so mode A skips via the `--! modes: B,R` header).

## Loading

The fork does not create a global `ffi` (5.4 parity, no PUC global). Use
`local F = require("ffi")`; `bit` remains a global LuaJIT extension.

## cdata representation

`int64_t`/`uint64_t` are FFI cdata, not Lua numbers:
- `tostring(cdata)` appends `LL` (int64_t) or `ULL` (uint64_t), e.g. `42LL`,
  `18446744073709551615ULL`; strip the suffix before parsing as text.
- `math.type(cdata)` returns `nil` (cdata is neither integer nor float).
- `F.sizeof("int64_t")` and `F.sizeof("uint64_t")` are 8.

## Construction and arithmetic

- `F.new("int64_t", 1<<62)` → `"4611686018427387904LL"`.
- `int64_t op int64_t` → `cdata<int64_t>`; `uint64_t op uint64_t` →
  `cdata<uint64_t>`; mixed signed/unsigned → `cdata<uint64_t>` (unsigned wins).
- Native Lua integer + cdata → cdata; the cdata side's type wins.
- Supported: `+ - * / % ^` and unary minus. Division/modulo truncates toward
  the C operator for the signedness.
- `//` (5.4 idiv) is **not supported on cdata**: runtime error "attempt to
  perform arithmetic on a cdata value".
- Division by zero returns the sentinel bit pattern `0x8000000000000000`:
  `-9223372036854775808LL` (signed) / `9223372036854775808ULL` (unsigned).
  `int64_min / -1` returns `int64_min`; `int64_min % -1` is `0LL`.

## Comparison

- int64_t comparisons are signed; uint64_t comparisons are unsigned.
- `int64_t == uint64_t` with the same 64-bit pattern is true (raw-bit compare).
- Comparison against native Lua integers works and returns boolean.

## Conversion

- `tonumber(cdata)` returns a Lua **float**: int64 sign-extended, uint64
  zero-extended, exact while within double precision; above 2^53 it rounds.
- `math.tointeger(cdata)` is **not supported** in this fork and returns `nil`.
- `F.cast("uint64_t", int64(-1))` and `F.cast("int64_t", uint64(max))`
  preserve the bit pattern (`18446744073709551615ULL`, `-1LL`).
- `string.format("%d", int64)` prints signed decimal; `%d` on a uint64 uses the
  signed interpretation (`uint64(1<<63)` → `-9223372036854775808`). Use `%u`
  for unsigned decimal; `%x` prints 16 hex digits for 64-bit cdata.

## bit library

Names are `bit.lshift` / `bit.rshift` (not `shl`/`shr`); `bit.rol`/`bit.ror`
exist. Measured 64-bit behavior:
- `bit.bnot(uint64 0xffffffff)` → `0xffffffff00000000` (`…4320ULL`);
  `bit.bnot(int64 42)` → `-43LL`.
- `bit.band/bor/bxor` operate on the full 64-bit value; masks above 2^32 are
  preserved (`0x1_00000000 & 0xffffffff_00000000` → `0x1_00000000`).
- `bit.tobit(cdata)` truncates to the low 32 bits (`uint64 0x100000000` → 0;
  `int64 -1` → -1).
- `bit.tohex(uint64 max)` → `ffffffffffffffff`;
  `bit.tohex(int64 -1, 8)` → `ffffffff`.
- `bit.lshift/rshift/arshift/rol/ror` were broken on arm64 (returned 0 for
  native and cdata). Fixed in `6e4d7bb9`; the regression is covered by
  `tests/lib/bit-checkint.lua` (`-joff` and `-jon`), while the portable ffi_int
  test still asserts only `tohex` and `band/bor/bxor/bnot/tobit`.

### Native 5.4 integers in bit.* (hybrid rule, decided 2026-11-17)

A native integer is an int32, a widened 47-bit inline integer or an interned
int64 box; `bit.*` never distinguishes the three.
- **Pure-number call** (int32, widened/boxed int64, float, numeric string; no
  64-bit cdata): stock semantics. Every operand wraps modulo 2^32 like
  `bit.tobit`, the result is an int32. `bit.band((1<<40)|0xff, 0x0f)` → 15,
  `bit.lshift((1<<40)+3, 1)` → 6, `bit.tobit(0xffffffff)` → -1,
  `bit.tohex((1<<40)|0xff)` → `000000ff` (and `00000000000000ff` with 16
  digits), `bit.band(2^32+1, 0xffffffff00000000)` → 0 while
  `(2^32+1) & 0xffffffff00000000` → 4294967296. Exact 64-bit work uses the
  5.4 operators.
- **Mixed call** (a 64-bit cdata value operand): native integers take part
  with their exact 64-bit value, the way stock converts a Lua number in a
  mixed call; the result is cdata of the cdata operand's rank.
  `bit.band(uint64 max, (1<<40)|0xff)` → `1099511628031ULL`, the same as with
  an `int64_t` partner; `bit.bor((1<<40)|0xff, int64 1)` → `1099511628031LL`
  (argument order does not matter); an int32 sign-extends
  (`bit.band(uint64 max, -1)` → `18446744073709551615ULL`).
- **Shifts and `tohex`** decide by the value operand, as stock does: the count
  always wraps to int32. `bit.lshift(int64 1, (1<<40)+3)` → `8LL` (count
  modulo 2^32 = 3); `bit.lshift((1<<40)+3, int64 1)` → 6 (int32 result);
  `bit.tohex((1<<40)|0xff, int64 16)` → `00000000000000ff`.
- Mechanism: `lj_carith_check64` returns the exact value and no longer writes
  the slot; a pure call narrows widened/boxed slots in place
  (`bit_narrow_args`, `src/lib_bit.c`) before `FFH_RETRY`, so the asm fast
  function reruns on int32 instead of falling back again (the retry loop of
  `6e4d7bb9`). Non-FFI builds (`LUAJIT_DISABLE_FFI`) narrow the same way in
  `bit_checkbit`; note that such a build is not a supported configuration of
  this fork anyway — its 5.4 operators keep the legacy 32-bit path in
  `lj_meta_bitop` (`1<<40` evaluates to 256 there).
- JIT: the bit library records through `lj_opt_narrow_bitop` (TOBIT for
  floats, truncating `CONV int.i64` for widened/boxed, STRTO for strings), so
  pure calls with any operand type compile and match `-joff`. Mixed calls with
  a native int64 operand leave the trace (`crec_ct_tv` has no IRT_I64 source)
  and run in the interpreter with the same result. The 5.4 operators keep
  `lj_opt_narrow_tobit`, which only accepts int32 (exact semantics; float
  operands of `&`/`|` stay in the interpreter).

## Tests and gate

Each test is a purposeful differential/self-check in modes B (JIT on/off) and
R (dump/reload); mode A skips because PUC has no ffi/bit. Measured after the
nil-`ffi` bug was fixed: 6 PASS / 0 FAIL per box (arm64 and x86_64), with every
assertion checking measured stock-LuaJIT/fork behavior.
