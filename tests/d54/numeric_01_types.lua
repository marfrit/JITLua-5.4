--! §4.1 two number types; math.type; integer vs float rendering
-- Differential test: prints behavior, harness compares PUC 5.4.9 vs ours.
-- Parseable by Lua 5.1 (no 5.4-only syntax) so mode A gives semantic diffs.

local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

p("math.type", math.type(3), math.type(3.0), math.type("3"), math.type(nil))
p("literal types", math.type(0), math.type(0.0), math.type(1e2), math.type(0x10))
p("tostring", tostring(3), tostring(3.0), tostring(-0.0), tostring(1e15), tostring(1e16))
p("maxinteger", math.maxinteger, math.mininteger)
p("maxint type", math.type(math.maxinteger), math.type(math.maxinteger + 0.0))
p("wrap add", math.maxinteger + 1, math.mininteger - 1)
p("wrap mul", math.maxinteger * 2, math.mininteger * 2)
p("float keep", 3 / 1, math.type(3 / 1), 2 ^ 2, math.type(2 ^ 2))
p("mixed", math.type(1 + 1.0), math.type(1 * 1.0), math.type(1 - 1.0))
p("int div exact", 6 / 3, math.type(6 / 3))
p("unary minus", -3, math.type(-3), -3.0, math.type(-3.0), -math.mininteger)
p("tointeger", math.tointeger(3.0), math.tointeger(3.5), math.tointeger(-0.0),
  math.tointeger(1e18), math.tointeger("3"), math.tointeger(2 ^ 63))
p("floor/ceil type", math.type(math.floor(3.7)), math.type(math.ceil(3.2)),
  math.floor(3.7), math.ceil(3.2), math.floor(-3.7))
p("abs minint", math.abs(math.mininteger), math.type(math.abs(math.mininteger)))
p("huge", math.huge, -math.huge, math.type(math.huge))
assert(math.maxinteger + 1 == math.mininteger, "integer arithmetic must wrap mod 2^64")
assert(math.type(2 ^ 2) == "float", "^ always yields float in 5.4")
