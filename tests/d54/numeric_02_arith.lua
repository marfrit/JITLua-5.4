--! §4.1 + - * / on ints stay ints (wrap), mixed pairs coerce, / always float
-- Parseable by Lua 5.1.

local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function ty(v) return math.type(v) end

p("int add", 2 + 3, ty(2 + 3))
p("int sub", 2 - 3, ty(2 - 3))
p("int mul", 6 * 7, ty(6 * 7))
p("float div", 7 / 2, ty(7 / 2), 6 / 3, ty(6 / 3))
p("mixed add", 1 + 0.5, ty(1 + 0.5), 0.5 + 1, ty(0.5 + 1))
p("mixed mul", 3 * 1.5, ty(3 * 1.5))
p("mixed sub", 3 - 1.5, ty(3 - 1.5))
p("div by zero int", pcall(function() return 1 / 0 end))
p("div zero float", 1.0 / 0, -1.0 / 0, ty(1.0 / 0))
p("overflow to float", math.maxinteger + 1.0, ty(math.maxinteger + 1.0))
p("big mul wrap", 4611686018427387904 * 2, 4611686018427387904 * 4)
p("neg minint", -math.mininteger, ty(-math.mininteger))
p("int overflow chain", math.maxinteger + 1 + 1, math.maxinteger * 3)
p("float precision", 2 ^ 53, 2 ^ 53 + 1, 2 ^ 53 + 1.0, (2 ^ 53 + 1) == 2 ^ 53)
p("exact cross cmp", 9007199254740993 == 9007199254740992.0,
  9007199254740993 > 2 ^ 53, 2 ^ 53 < 9007199254740993)
p("string coercion", "10" + 5, "0x10" + 0, "  12  " + 0, "1e2" * 2)
p("string coercion fail", pcall(function() return "abc" + 1 end))
p("concat numbers", 1 .. 2, 1.5 .. "", 1.0 .. "")
p("arith assoc", 1 + 2 * 3, (1 + 2) * 3, 2 ^ 3 ^ 2, (2 ^ 3) ^ 2)
p("unary precedence", -2 ^ 2, (-2) ^ 2, -2 ^ -2)
assert(7 / 2 == 3.5 and math.type(7 / 2) == "float")
assert(math.maxinteger * 2 == -2, "wrap")
