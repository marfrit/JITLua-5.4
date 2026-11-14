--! §4.1 % : integer result for ints (sign of divisor), float otherwise (5.4 floor-mod)
-- Parseable by Lua 5.1 (5.1 % is fmod-like: sign of dividend -- the delta).

local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

p("int mod", 5 % 3, -5 % 3, 5 % -3, -5 % -3)
p("int mod type", math.type(5 % 3), math.type(-5 % 3))
p("float mod", 5.5 % 2, -5.5 % 2, 5.5 % -2, -5.5 % -2)
p("float mod type", math.type(5.5 % 2), math.type(-5.5 % 2))
p("mixed mod", 5 % 2.0, -5 % 2.0, math.type(5 % 2.0))
p("mod identity", 7 % 3 + 3 * (7 // 3 == 0 and 0 or 0))
p("mod zero", pcall(function() return 1 % 0 end))
p("float mod zero", 1.0 % 0, -1.0 % 0)
p("minint mod", math.mininteger % -1, math.mininteger % 2, math.maxinteger % 2)
p("fmod vs mod", math.fmod(-5, 3), -5 % 3, math.fmod(5, -3), 5 % -3)
p("fmod float", math.fmod(-5.5, 2), -5.5 % 2, math.fmod(5.5, -2), 5.5 % -2)
p("mod precedence", 2 + 5 % 3, 5 % 3 * 2, 2 ^ 3 % 3)
p("mod large", 1000000000000000000 % 7, -1000000000000000000 % 7)
p("mod tiny float", 0.1 % 0.03, -0.1 % 0.03)
assert(-5 % 3 == 1, "5.4 integer % takes the sign of the divisor")
assert(-5.5 % 2 == 0.5, "5.4 float % is floor-mod, not fmod")
assert(math.fmod(-5, 3) == -2, "math.fmod keeps C semantics")
