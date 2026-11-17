-- Regression for c6284a6d: arm64 checkint clobbered TMP0, so the bit.* fast functions
-- (shifts, multi-argument band/bor/bxor) returned 0 in the interpreter. Self-checking:
-- exits 1 on any mismatch. Run with -joff and -jon.
local bit = require("bit")
local fails = 0
local function eq(name, got, want)
  if got ~= want then fails = fails + 1; print("FAIL " .. name, got, want) end
end
local min32 = -2147483647 - 1
eq("lshift", bit.lshift(1, 8), 256);       eq("lshift31", bit.lshift(1, 31), min32)
eq("rshift", bit.rshift(256, 4), 16);      eq("rshift-neg", bit.rshift(-1, 31), 1)
eq("arshift", bit.arshift(-256, 4), -16);  eq("rol", bit.rol(1, 1), 2)
eq("ror", bit.ror(1, 1), min32)
eq("band2", bit.band(0xff, 0x0f), 0x0f);   eq("band3", bit.band(7, 6, 5), 4)
eq("bor4", bit.bor(1, 2, 4, 8), 15);       eq("bxor2", bit.bxor(0xff, 0x0f), 0xf0)
eq("tobit", bit.tobit(0xffffffff), -1);    eq("bnot", bit.bnot(0), -1)
eq("bswap", bit.bswap(0x12345678), 0x78563412)
-- widened (47-bit) inputs must take the C fallback and wrap to 32 bits
eq("lshift-wide", bit.lshift((1 << 40) + 3, 1), 6)
eq("band-wide", bit.band((1 << 40) | 0xff, 0x0f), 0x0f)
eq("tobit-wide", bit.tobit((1 << 40) + 5), 5)
-- boxed int64 (>= 2^47) arguments take the tvisi64 branch of lj_carith_check64
eq("lshift-boxed", bit.lshift((1 << 50) + 3, 1), 6)
eq("band-boxed", bit.band((1 << 50) | 0xff, 0x0f), 0x0f)
eq("tobit-boxed", bit.tobit((1 << 60) + 7), 7)
-- hot loops (traces) must agree with the closed forms
local s, a, o = 0, 0, 0
for i = 1, 300 do
  s = s + bit.lshift(i, 2) + bit.rshift(i * 16, 4)
  a = bit.bxor(a, bit.band(i, 0x5a, 0xff))
  o = bit.bor(o, bit.lshift(1, i % 31))
end
local ws, wa = 0, 0
for i = 1, 300 do ws = ws + i * 4 + i; wa = wa ~ (i & 0x5a) end
eq("loop-shift", s, ws); eq("loop-band", a, wa); eq("loop-bor", o, 0x7fffffff)
print(fails == 0 and "bit-checkint ok" or ("bit-checkint FAILED " .. fails))
if fails ~= 0 then os.exit(1) end
