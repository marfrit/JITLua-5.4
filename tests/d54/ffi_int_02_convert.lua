--! modes: B,R
-- FFI int64_t/uint64_t conversions vs native 5.4 integers (stock LuaJIT model).
local F = require("ffi")
local function p(label, ...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
  print(label .. " | " .. table.concat(t, " | "))
end

local i64 = F.new("int64_t", 42)
local u64 = F.new("uint64_t", 42)
p("tonumber", tonumber(i64), tonumber(u64), math.type(tonumber(i64)))
assert(tonumber(i64) == 42 and tonumber(u64) == 42)
assert(math.type(tonumber(i64)) == "float")  -- LuaJIT tonumber(cdata) yields float

local big = F.new("int64_t", 1 << 62)
p("tonumber-big", tonumber(big))
assert(tonumber(big) == 1 << 62)
local neg = F.new("int64_t", -100)
assert(tonumber(neg) == -100)
local maxu = F.new("uint64_t", 0xffffffffffffffff)
p("tonumber-max-u64", tonumber(maxu))
assert(tonumber(maxu) == 2^64)  -- rounded double

-- math.tointeger(cdata) is not supported in this fork (cdata is not a number).
p("tointeger", math.tointeger(i64), math.tointeger(u64), math.tointeger(big))
assert(math.tointeger(i64) == nil and math.tointeger(u64) == nil and math.tointeger(big) == nil)

p("cast", tostring(F.cast("uint64_t", F.new("int64_t", -1))),
  tostring(F.cast("int64_t", F.new("uint64_t", 0xffffffffffffffff))))
assert(tostring(F.cast("uint64_t", F.new("int64_t", -1))) == "18446744073709551615ULL")
assert(tostring(F.cast("int64_t", F.new("uint64_t", 0xffffffffffffffff))) == "-1LL")
assert(tostring(F.cast("int64_t", 42)) == "42LL")

p("format", string.format("%d", i64), string.format("%d", u64),
  string.format("%d", F.new("uint64_t", 1 << 63)),
  string.format("%d", neg), string.format("%u", F.new("uint64_t", 1 << 63)),
  string.format("%x", F.new("uint64_t", 0xffffffffffffffff)),
  string.format("%x", F.new("int64_t", -1)))
assert(string.format("%d", i64) == "42" and string.format("%d", u64) == "42")
assert(string.format("%d", F.new("uint64_t", 1 << 63)) == "-9223372036854775808")
assert(string.format("%d", neg) == "-100")
assert(string.format("%u", F.new("uint64_t", 1 << 63)) == "9223372036854775808")
assert(string.format("%x", F.new("uint64_t", 0xffffffffffffffff)) == "ffffffffffffffff")
assert(string.format("%x", F.new("int64_t", -1)) == "ffffffffffffffff")

p("tostring", tostring(big))
assert(tostring(big) == "4611686018427387904LL")
-- int64_t/uint64_t print with an LL/ULL suffix; strip it to re-parse.
local txt = tostring(big)
local num = tonumber(txt:match("^(%-?%d+)"))
p("roundtrip", txt, num)
assert(num == 1 << 62)
