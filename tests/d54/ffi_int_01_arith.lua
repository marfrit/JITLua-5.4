--! modes: B,R
-- FFI int64_t/uint64_t arithmetic vs native Lua integers (stock LuaJIT model).
-- Cdata int64/uint64 are distinct FFI types; tostring() disambiguates 8-byte
-- integers with LL (signed) / ULL (unsigned). Native integers are signed 64-bit.
local F = require("ffi")
local function p(label, ...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
  print(label .. " | " .. table.concat(t, " | "))
end
local function try(f, ...)
  local ok, r = pcall(f, ...)
  return "ok=" .. tostring(ok) .. " r=" .. tostring(r)
end

local i64 = F.new("int64_t", 42)
local u64 = F.new("uint64_t", 42)
p("new", F.sizeof("int64_t"), F.sizeof("uint64_t"), tostring(i64), tostring(u64),
  math.type(i64), math.type(u64))
assert(tostring(i64) == "42LL" and tostring(u64) == "42ULL")
assert(math.type(i64) == nil and math.type(u64) == nil)  -- cdata is not a Lua number type

local big = F.new("int64_t", 1 << 62)
local ubig = F.new("uint64_t", 1 << 63)
p("big", tostring(big), tostring(ubig))
assert(tostring(big) == "4611686018427387904LL")
assert(tostring(ubig) == "9223372036854775808ULL")

local a, b = F.new("int64_t", 100), F.new("int64_t", 200)
local ua, ub = F.new("uint64_t", 100), F.new("uint64_t", 200)
p("add", tostring(a + b), tostring(ua + ub), tostring(a + ua),
  math.type(a + b), math.type(a + ua))
assert(tostring(a + b) == "300LL")
assert(tostring(ua + ub) == "300ULL")
assert(tostring(a + ua) == "200ULL")   -- mixed signed/unsigned -> uint64
assert(math.type(a + b) == nil)        -- result is cdata, not a Lua integer

p("sub", tostring(a - b))
assert(tostring(a - b) == "-100LL")
local biga = F.new("int64_t", 1 << 30)
p("mul", tostring(biga * biga))
assert(tostring(biga * biga) == "1152921504606846976LL")

local d1 = F.new("int64_t", -7)
p("div", tostring(d1 / F.new("int64_t", 3)),
  tostring(F.new("uint64_t", 7) / F.new("uint64_t", 3)))
assert(tostring(d1 / F.new("int64_t", 3)) == "-2LL")
assert(tostring(F.new("uint64_t", 7) / F.new("uint64_t", 3)) == "2ULL")

-- 5.4 // is not defined on cdata in this fork: it raises a runtime error.
p("idiv-unsupported", try(function() return d1 // F.new("int64_t", 3) end))

p("mod", tostring(d1 % F.new("int64_t", 3)),
  tostring(F.new("uint64_t", 7) % F.new("uint64_t", 3)))
assert(tostring(d1 % F.new("int64_t", 3)) == "-1LL")
assert(tostring(F.new("uint64_t", 7) % F.new("uint64_t", 3)) == "1ULL")

local pw = F.new("int64_t", 2)
p("pow", tostring(pw ^ F.new("int64_t", 10)))
assert(tostring(pw ^ F.new("int64_t", 10)) == "1024LL")
p("unm", tostring(-F.new("int64_t", 42)))
assert(tostring(-F.new("int64_t", 42)) == "-42LL")

local c1, c2 = F.new("int64_t", -1), F.new("int64_t", 1)
local uc1, uc2 = F.new("uint64_t", 1 << 63), F.new("uint64_t", 1)
p("cmp", c1 < c2, c1 > c2, c1 == c2, uc1 > uc2,
  F.new("int64_t", 42) == F.new("uint64_t", 42))
assert(c1 < c2 and not (c1 > c2) and not (c1 == c2))
assert(uc1 > uc2)  -- unsigned comparison
assert(F.new("int64_t", -1) == F.new("uint64_t", -1))  -- same 64-bit pattern
p("neg-u64", tostring(F.new("uint64_t", -1)))
assert(tostring(F.new("uint64_t", -1)) == "18446744073709551615ULL")

local native = 100
local cv = F.new("int64_t", 200)
p("native", tostring(native + cv), tostring(cv + native),
  tostring(native + F.new("uint64_t", 200)))
assert(tostring(native + cv) == "300LL")
assert(tostring(cv + native) == "300LL")
assert(tostring(native + F.new("uint64_t", 200)) == "300ULL")

p("divzero", tostring(F.new("int64_t", 1) / F.new("int64_t", 0)),
  tostring(F.new("uint64_t", 1) / F.new("uint64_t", 0)))
assert(tostring(F.new("int64_t", 1) / F.new("int64_t", 0)) == "-9223372036854775808LL")
assert(tostring(F.new("uint64_t", 1) / F.new("uint64_t", 0)) == "9223372036854775808ULL")
local minint = F.new("int64_t", -9223372036854775808)
p("min-div", tostring(minint / F.new("int64_t", -1)), tostring(minint % F.new("int64_t", -1)))
assert(tostring(minint / F.new("int64_t", -1)) == "-9223372036854775808LL")
assert(tostring(minint % F.new("int64_t", -1)) == "0LL")
