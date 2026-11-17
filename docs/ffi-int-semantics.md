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
- `bit.lshift/rshift/arshift/rol/ror` are **broken on arm64** in this fork:
  they return 0 for both cdata and native arguments, under `-joff` and `-jon`
  alike (x64 returns the proper 32-bit native / 64-bit cdata result). This is
  not a JIT fast-path issue; root cause not yet located. The portable test does
  not assert shifts; `tohex` plus `band/bor/bxor/bnot/tobit` are covered.

## Tests and gate

Each test is a purposeful differential/self-check in modes B (JIT on/off) and
R (dump/reload); mode A skips because PUC has no ffi/bit. Measured after the
nil-`ffi` bug was fixed: 6 PASS / 0 FAIL per box (arm64 and x86_64), with every
assertion checking measured stock-LuaJIT/fork behavior.
