--! §4.1/§4.2 __len may return ANY value and applies to tables; __pairs is
--! honored by pairs(); __ipairs is NOT honored (removed in 5.4).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("len float", #setmetatable({}, { __len = function() return 2.5 end }))
p("len string", #setmetatable({}, { __len = function() return "x" end }))
p("len table", #setmetatable({}, { __len = function() return { 1 } end }))
p("len type", math.type(#setmetatable({}, { __len = function() return 3.0 end })))
p("len plain", #{ 1, 2, 3 }, #{}, #"abc")
p("len no mm", #setmetatable({ 1, 2 }, {}))
p("len err", pcall(function() return #setmetatable({}, {}) + 0 end))
p("len userdata", pcall(function() return #io.tmpfile() end))
local pm = setmetatable({ 1, 2 }, { __pairs = function(t)
  return function() return nil end, {}, nil
end })
local c = 0
for k, v in pairs(pm) do c = c + 1 end
p("pairs mm", c)
local pm2 = setmetatable({ 1, 2 }, { __pairs = function(t)
  local i = 0
  return function() i = i + 1; if i <= 3 then return i, i * 10 end end, t, 0
end })
local acc = {}
for k, v in pairs(pm2) do acc[#acc + 1] = k .. "=" .. v end
p("pairs mm custom", table.concat(acc, ","))
p("pairs plain", (function() local n = 0 for k in pairs({ 1, 2, 3 }) do n = n + 1 end return n end)())
local im = setmetatable({ 1, 2 }, { __ipairs = function()
  return function() return nil end, {}, nil
end })
c = 0
for i, v in ipairs(im) do c = c + 1 end
p("ipairs mm ignored", c)
-- JIT hot paths must agree with the interpreter.
local r
for i = 1, 500 do r = #setmetatable({}, { __len = function() return 2.5 end }) end
p("jit len", r)
for i = 1, 500 do
  c = 0
  for k in pairs(setmetatable({ 1, 2 }, { __pairs = function() return next, {}, nil end })) do c = c + 1 end
end
p("jit pairs", c)
for i = 1, 500 do r = #{ 1, 2, 3 } end
p("jit plain len", r)
