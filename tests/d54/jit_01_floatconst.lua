--! §4.1/§4.3 JIT must preserve float-ness of constants (5.4: 3.0 ~= 3).
--! Regression: the recorder narrowed integral float constants to KINT, and
--! the ".0" tostring suffix once used a stale buffer pointer (segfault).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
-- Hot loops so the JIT compiles these paths.
local r = {}
for i = 1, 500 do
  r[1] = math.type(3.0)
  r[2] = math.type(3)
  r[3] = (3.0 .. "")
  r[4] = tostring(3.0)
  r[5] = tostring(-0.0)
  r[6] = table.concat({ 3.0, 4.0 }, ",")
  r[7] = table.concat({ 3.5 })
  r[8] = string.format("%g", 3.0)
  r[9] = 3.0 + 0
  r[10] = math.type(3.0 + 0)
end
p("types", r[1], r[2])
p("concat", r[3], r[6], r[7])
p("tostring", r[4], r[5])
p("format", r[8])
p("arith", r[9], r[10])
-- Non-constant floats through the same paths.
local x = 3.0
local s
for i = 1, 500 do s = x .. "|" .. tostring(x) end
p("var", s)
-- Table keys: integer 3 and float 3.0 are the same key in Lua, but the
-- *value* type must survive.
local t = {}
for i = 1, 500 do t[3.0] = 3.0 end
p("key", math.type(t[3]), t[3] == 3, math.type(t[3]) == "float")
