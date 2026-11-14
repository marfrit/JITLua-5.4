--! §4.1 __eq __lt __le cross-type; §4.2 __len any value; __pairs/__ipairs absent
-- Parseable by Lua 5.1.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("int float eq", 1 == 1.0, 1 == 1.5, 2 ^ 53 == 9007199254740992,
  2 ^ 53 == 9007199254740993, 9007199254740993 == 2 ^ 53)
p("cross lt le", 1 < 1.0, 1 <= 1.0, 1.5 < 2, 2 <= 2.0, -0.0 == 0)
p("big cross", math.maxinteger > 2 ^ 62, math.maxinteger < 2 ^ 63,
  math.mininteger < -2 ^ 62, 2 ^ 63 > math.maxinteger)
local eq = setmetatable({}, { __eq = function() return true end })
p("eq mm same mt", eq == eq, eq == setmetatable({}, getmetatable(eq)))
p("eq mm vs int", eq == 1, 1 == eq)
p("eq mm vs str", eq == "x")
local lt = setmetatable({}, { __lt = function(a, b) return true end,
                             __le = function(a, b) return false end })
local lt2 = setmetatable({}, getmetatable(lt))
p("lt mm", lt < lt2, lt2 < lt, lt <= lt2, lt < 1)
p("lt mm mixed types", pcall(function() return lt < "x" end))
p("len table", #setmetatable({}, { __len = function() return 2.5 end }))
p("len string mm", #setmetatable({}, { __len = function() return "x" end }))
p("len type", math.type(#setmetatable({}, { __len = function() return 3.0 end })))
p("len plain", #{ 1, 2, 3 }, #{ 1, nil, 3 }, #{}, #("abc"))
p("len border", #{ 1, 2, nil, 4 }, (function() local t = {} for i = 1, 5 do t[i] = i end t[3] = nil return #t end)())
local pm = setmetatable({ 1, 2 }, { __pairs = function() return function() return nil end, {}, nil end })
local c = 0; for k, v in pairs(pm) do c = c + 1 end
p("pairs mm ignored", c)
local im = setmetatable({ 1, 2 }, { __ipairs = function() return function() return nil end, {}, nil end })
c = 0; for i, v in ipairs(im) do c = c + 1 end
p("ipairs mm ignored", c)
assert(9007199254740993 ~= 2 ^ 53, "int/float comparison must be exact")
assert(#setmetatable({}, { __len = function() return 2.5 end }) == 2.5)
