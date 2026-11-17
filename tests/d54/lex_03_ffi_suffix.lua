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

-- 5.4 numeral token rules stay: a non-FFI letter is malformed and reports
-- exactly one trailing char, and a bad suffix still malforms with its token.
local f, msg = load("return 1p")
print("bad1p", f, msg)
assert(not f and msg:find("malformed number", 1, true) and msg:find("1p", 1, true))
local g, msg2 = load("return 1LLx")
print("badLLx", g, msg2)
assert(not g and msg2:find("malformed number", 1, true) and msg2:find("1LLx", 1, true))
