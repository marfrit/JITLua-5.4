--! §4.1 // floor division: int floor for ints, float floor for floats/mixed
-- 5.4-only syntax: unported 2.1 fails at parse time (expected, mode A).

local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

p("int idiv", 7 // 2, -7 // 2, 7 // -2, -7 // -2)
p("int idiv type", math.type(7 // 2), math.type(-7 // 2))
p("float idiv", 7.0 // 2, -7.0 // 2, 7.0 // -2, -7.0 // -2)
p("float idiv type", math.type(7.0 // 2), math.type(-7.0 // 2))
p("mixed idiv", 7 // 2.0, -7 // 2.0, math.type(7 // 2.0))
p("exact", 6 // 3, 6.0 // 3, -6 // 3)
p("minint // -1", math.mininteger // -1, math.mininteger % -1)
p("minint // 1", math.mininteger // 1, math.mininteger // 2)
p("maxint // -1", math.maxinteger // -1)
p("zero divisor", pcall(function() return 1 // 0 end))
--! NaN *sign* is implementation-defined per the CPU/OS (PUC 5.4.7 gives
--! -nan on x86_64 and nan on aarch64); canonicalise only the NaN sign here so
--! this test compares semantics, not the platform's QNaN bit.
local function nz(v)
  local s = tostring(v)
  if s == "nan" or s == "-nan" then return "nan" end
  return s
end
p("float zero divisor", nz(1.0 // 0), nz(-1.0 // 0), nz(0.0 // 0))
p("inf idiv", nz(math.huge // 2), nz(-math.huge // 2), nz(math.huge // math.huge))
p("tiny", 1 // 2, -1 // 2, 1 // 3, -1 // 3)
p("idiv precedence", 2 + 6 // 2, 6 // 2 * 3, 2 ^ 3 // 2)
p("idiv vs floor", math.floor(7 / 2), 7 // 2, math.floor(-7 / 2), -7 // 2)
p("float floor idiv", math.floor(7.5 / 2), 7.5 // 2, -7.5 // 2)
assert(7 // 2 == 3 and -7 // 2 == -4, "integer // floors toward -inf")
assert(math.type(7 // 2) == "integer" and math.type(7.0 // 2) == "float")
assert(math.mininteger // -1 == math.mininteger, "INT64_MIN // -1 wraps")
