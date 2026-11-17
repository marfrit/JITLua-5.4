-- Regression for cb2f6da2 (arm64 checkint clobbered TMP0: the bit.* shifts and the
-- multi-argument band/bor/bxor returned 0 in the interpreter) and acceptance test
-- for the hybrid rule of native 5.4 integers in bit.* (docs/ffi-int-semantics.md):
-- a pure-number call wraps every operand modulo 2^32 and returns an int32; a call
-- with a 64-bit cdata value operand uses the exact 64-bit value of native
-- integers and returns cdata. Every row runs under pcall, so one failure or error
-- cannot hide the others. Exits 1 on any mismatch. Run with -joff and -jon.
local bit = require("bit")
local fails = 0
local function eq(name, f, want)
  local ok, got = pcall(f)
  if not ok then got = "ERROR: " .. tostring(got) end
  if ok and type(got) == "cdata" then got = tostring(got) end
  if type(want) == "cdata" then want = tostring(want) end
  if got ~= want then fails = fails + 1; print("FAIL " .. name, got, want) end
end
local min32 = -2147483647 - 1
local w = (1 << 40) + 3          -- widened 47-bit inline integer
local wm = (1 << 40) | 0xff
local b = (1 << 50) + 3          -- boxed int64 (beyond the 47-bit inline range)
local bm = (1 << 50) | 0xff
local u32 = 0xffffffff           -- [2^31, 2^32): boxed too (no inline encoding)

-- int32 fast paths (the cb2f6da2 regression)
eq("lshift", function() return bit.lshift(1, 8) end, 256)
eq("lshift31", function() return bit.lshift(1, 31) end, min32)
eq("rshift", function() return bit.rshift(256, 4) end, 16)
eq("rshift-neg", function() return bit.rshift(-1, 31) end, 1)
eq("arshift", function() return bit.arshift(-256, 4) end, -16)
eq("rol", function() return bit.rol(1, 1) end, 2)
eq("ror", function() return bit.ror(1, 1) end, min32)
eq("band2", function() return bit.band(0xff, 0x0f) end, 0x0f)
eq("band3", function() return bit.band(7, 6, 5) end, 4)
eq("bor4", function() return bit.bor(1, 2, 4, 8) end, 15)
eq("bxor2", function() return bit.bxor(0xff, 0x0f) end, 0xf0)
eq("bnot", function() return bit.bnot(0) end, -1)
eq("bswap", function() return bit.bswap(0x12345678) end, 0x78563412)
eq("tohex", function() return bit.tohex(-1) end, "ffffffff")

-- pure-number calls wrap modulo 2^32: widened, boxed, [2^31,2^32), floats, strings
eq("tobit-u32", function() return bit.tobit(u32) end, -1)
eq("lshift-wide", function() return bit.lshift(w, 1) end, 6)
eq("band-wide", function() return bit.band(wm, 0x0f) end, 0x0f)
eq("tobit-wide", function() return bit.tobit(w + 2) end, 5)
eq("bnot-wide", function() return bit.bnot(w) end, -4)
eq("shcount-wide", function() return bit.lshift(1, w) end, 8)      -- count mod 2^32 = 3
eq("tohex-wide", function() return bit.tohex(wm) end, "000000ff")
eq("tohex-wide16", function() return bit.tohex(wm, 16) end, "00000000000000ff")
eq("lshift-boxed", function() return bit.lshift(b, 1) end, 6)
eq("band-boxed", function() return bit.band(bm, 0x0f) end, 0x0f)
eq("bor-boxed", function() return bit.bor(bm, 0x100) end, 0x1ff)
eq("tobit-boxed", function() return bit.tobit((1 << 60) + 7) end, 7)
eq("band-wide-wide", function() return bit.band(4294967297, 0xffffffff00000000) end, 0)
eq("tobit-float", function() return bit.tobit(2^40 + 5) end, 5)
eq("band-string", function() return bit.band("1099511627779", 0xff) end, 3)
eq("type-wide", function() return math.type(bit.band(wm, 0x0f)) end, "integer")
eq("arg-survives", function() local x = w; bit.tobit(x); return x end, w)

-- mixed calls: a 64-bit cdata value operand promotes native integers to their exact value
local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi then
  local ones = ffi.new("uint64_t", -1)
  local i64 = ffi.new("int64_t", 1)
  eq("mixed-band-wide", function() return bit.band(ones, wm) end, "1099511628031ULL")
  eq("mixed-band-boxed", function() return bit.band(ones, bm) end, ffi.new("uint64_t", bm))
  eq("mixed-bor-order", function() return bit.bor(wm, i64) end, "1099511628031LL")
  eq("mixed-band-u32", function() return bit.band(ones, u32) end, "4294967295ULL")
  eq("mixed-band-int32", function() return bit.band(ones, -1) end, "18446744073709551615ULL")
  eq("mixed-band3", function() return bit.band(wm, ones, 0xff) end, "255ULL")
  eq("mixed-bxor", function() return bit.bxor(ffi.new("int64_t", wm), wm) end, "0LL")
  eq("mixed-shift-cdata-value", function() return bit.lshift(i64, w) end, "8LL")  -- count mod 2^32
  eq("mixed-shift-cdata-count", function() return bit.lshift(w, i64) end, 6)      -- value decides
  eq("mixed-bnot-cdata", function() return bit.bnot(ffi.new("int64_t", w)) end, ffi.new("int64_t", ~w))
  eq("mixed-tohex-cdata", function() return bit.tohex(ffi.new("int64_t", wm)) end, "00000100000000ff")
  eq("mixed-tohex-native-n", function() return bit.tohex(wm, ffi.new("int64_t", 16)) end, "00000000000000ff")
  eq("mixed-tobit-cdata", function() return bit.tobit(ffi.new("int64_t", wm)) end, 0xff)
end

-- hot loops: traces must agree with the closed forms (widened, boxed, float and
-- mixed operands included: the recorder narrows them like the interpreter)
local s, a, o = 0, 0, 0
for i = 1, 300 do
  s = s + bit.lshift(i, 2) + bit.rshift(i * 16, 4)
  a = bit.bxor(a, bit.band(i, 0x5a, 0xff))
  o = bit.bor(o, bit.lshift(1, i % 31))
end
local ws, wa = 0, 0
for i = 1, 300 do ws = ws + i * 4 + i; wa = wa ~ (i & 0x5a) end
eq("loop-shift", function() return s end, ws)
eq("loop-band", function() return a end, wa)
eq("loop-bor", function() return o end, 0x7fffffff)
local sw, sb, sd, sh = 0, 0, 0, 0
for i = 1, 300 do
  sw = sw + bit.band(w + i, 0xff)         -- widened operand
  sb = sb + bit.band(b + i, 0xff)         -- boxed operand
  sd = sd + bit.band(2^40 + 3 + i, 0xff)  -- float operand
  sh = sh + bit.lshift(w, i % 8)          -- widened value, int32 count
end
local want, wanth = 0, 0
for i = 1, 300 do want = want + ((3 + i) & 0xff); wanth = wanth + (3 << (i % 8)) end
eq("loop-wide", function() return sw end, want)
eq("loop-boxed", function() return sb end, want)
eq("loop-float", function() return sd end, want)
eq("loop-shift-wide", function() return sh end, wanth)
if ok_ffi then
  local ones = ffi.new("uint64_t", -1)
  local acc = ffi.new("uint64_t", 0)
  for i = 1, 300 do acc = acc + bit.band(ones, w + i) end
  eq("loop-mixed", function() return acc end, ffi.new("uint64_t", 300 * w + 45150))
end
print(fails == 0 and "bit-checkint ok" or ("bit-checkint FAILED " .. fails))
if fails ~= 0 then os.exit(1) end
