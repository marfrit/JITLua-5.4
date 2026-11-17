--! modes: B,R
--! no-parse-check: LuaJIT FFI literal suffixes are invalid PUC 5.4 syntax
-- LuaJIT FFI literal suffixes are deliberate extensions kept by this fork:
-- LL (int64_t), ULL/LLU (uint64_t) and i (complex double), only when the
-- lexer has FFI support. They must work as real source literals, not strings.
local F = require("ffi")

local i64 = 1LL
local u64 = 1ULL
local hexu = 0x10ULL
local imag = 12.5i

print("i64", type(i64), tostring(i64), F.istype("int64_t", i64))
print("u64", type(u64), tostring(u64), F.istype("uint64_t", u64))
print("hexu", type(hexu), tostring(hexu), tonumber(hexu))
print("imag", type(imag), tostring(imag))

assert(type(i64) == "cdata" and F.istype("int64_t", i64))
assert(type(u64) == "cdata" and F.istype("uint64_t", u64))
assert(tostring(i64) == "1LL" and tonumber(i64) == 1)
assert(tostring(u64) == "1ULL" and tonumber(u64) == 1)
assert(tostring(hexu) == "16ULL" and tonumber(hexu) == 16)
assert(type(imag) == "cdata" and F.istype("complex", imag))
assert(imag.re == 0 and imag.im == 12.5)

-- Valid lowercase and LLU forms, and the integer wrap/extreme values.
local ll_lower = 1ll
local ull_lower = 1ull
local llu = 1LLU
print("lower", type(ll_lower), tostring(ll_lower), type(ull_lower),
  tostring(ull_lower), type(llu), tostring(llu))
assert(F.istype("int64_t", ll_lower) and tostring(ll_lower) == "1LL")
assert(F.istype("uint64_t", ull_lower) and tostring(ull_lower) == "1ULL")
assert(F.istype("uint64_t", llu) and tostring(llu) == "1ULL")
local wrap = 9223372036854775808LL
local neg_u = -1ULL
print("wrap", tostring(wrap), tostring(neg_u))
assert(tostring(wrap) == "-9223372036854775808LL")
assert(tostring(neg_u) == "18446744073709551615ULL")
local imag_e = 1e2i
local imag_hex = 0x1p4i
print("imag-exp", tostring(imag_e), tostring(imag_hex))
assert(F.istype("complex", imag_e) and imag_e.im == 100 and imag_e.re == 0)
assert(F.istype("complex", imag_hex) and imag_hex.im == 16 and imag_hex.re == 0)
local purehex = 0xffffffffffffffff
print("purehex", type(purehex), math.type(purehex), tostring(purehex))
assert(purehex == -1 and math.type(purehex) == "integer")

-- 5.4 numeral token rules stay: a non-FFI letter is malformed and reports
-- exactly one trailing char, and a bad suffix still malforms with its token.
local f, msg = load("return 1p")
print("bad1p", f, msg)
assert(not f and msg:find("malformed number", 1, true) and msg:find("1p", 1, true))
local g, msg2 = load("return 1LLx")
print("badLLx", g, msg2)
assert(not g and msg2:find("malformed number", 1, true) and msg2:find("1LLx", 1, true))

-- Suffixes that are not valid for the numeral form must be malformed.
local bad_suffixes = {
  "1.5LL", "0x1p4LL", "1e2LL", "1L", "1u", "1lu", "1Ul", "1LLi",
  "18446744073709551616ULL", "0x10000000000000000ULL"
}
for _, src in ipairs(bad_suffixes) do
  local f, err = load("return " .. src)
  print("bad", src, f, err)
  assert(not f, "accepted invalid suffix: " .. src)
  assert(err and err:find("malformed number", 1, true),
         "not a malformed-number error: " .. src)
end
