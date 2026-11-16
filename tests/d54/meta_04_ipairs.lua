---! 5.3+ ipairs honours __index: a proxy with a function __index, a proxy
---! whose __index is a table, a table with a metatable but no __index, a
---! metatable that appears/disappears between iterations, nil holes, and the
---! same under a hot loop. Mode A compares with PUC, mode B the JIT with the
---! interpreter.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(label, table.concat(t, " "))
end
local function collect(t) local r = {} for i, v in ipairs(t) do r[#r+1] = i .. "=" .. tostring(v) end return table.concat(r, ",") end
local backing = {10, 20, 30, nil, 50}
local proxy = setmetatable({}, {__index = function(_, k) return backing[k] end})
p("fn-index", collect(proxy))
local proxy2 = setmetatable({}, {__index = backing})
p("tab-index", collect(proxy2))
local plain = setmetatable({1, 2, 3}, {})
p("mt-no-index", collect(plain))
local mixed = setmetatable({"a", "b"}, {__index = function(_, k) if k <= 4 then return "x" .. k end end})
p("own-then-index", collect(mixed))
p("holes", collect({1, 2, nil, 4}))
p("nometa", collect({1, 2, 3}))
local calls = 0
local counted = setmetatable({}, {__index = function(_, k) calls = calls + 1; if k <= 3 then return k * k end end})
p("calls", collect(counted), calls)
-- __index returning false (not nil) continues
local fls = setmetatable({}, {__index = function(_, k) if k <= 3 then return false end end})
p("false", collect(fls))
-- hot loop: the JIT must take the same path
local s, n = 0, 0
for r = 1, 200 do
  for i, v in ipairs(proxy) do s = s + v; n = n + i end
  for i, v in ipairs(plain) do s = s + v end
end
p("hot", s, n)
local ro = setmetatable({}, {__index = {1, 2, 3, hello = "world"}, __len = function() return 3 end})
local r = {} for k, v in ipairs(ro) do r[k] = v end
p("readonly", #ro, #r, r[1], r[3], r[4])
