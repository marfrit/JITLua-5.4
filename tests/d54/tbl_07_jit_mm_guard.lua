--! §4.2 table library and the JIT: a trace recorded for plain tables must
--! not keep the raw fast path when a proxy (__index/__newindex/__len) or a
--! metatable that gains one later reaches the same compiled loop.
--! Differential against PUC 5.4.9 (mode A) and -joff vs -jon (mode B).
local function proxy(n)
  local store = {}
  for i = 1, n do store[i] = "s" .. i end
  return setmetatable({}, {
    __index = function(_, k) return store[k] end,
    __newindex = function(_, k, v) store[k] = v end,
    __len = function() return #store end,
  }), store
end

-- One loop sees plain tables first (the trace is recorded for them), then
-- proxies at the same call sites.
local list, stores = {}, {}
for i = 1, 400 do
  if i <= 300 then list[i] = { "a", "b" }
  else list[i], stores[i] = proxy(2) end
end
local acc, ok = {}, true
for i = 1, 400 do
  local t = list[i]
  table.insert(t, "c")
  acc[i] = table.concat(t, ",")
end
print("insert+concat", acc[1], acc[300], acc[301], acc[400])
print("proxy stores", stores[301][3], rawget(list[301], 3), stores[400][3])

-- A metatable without the metamethods while the loop gets hot; __index and
-- __len are added in the middle of the same loop.
local mt = {}
local t = setmetatable({ "1", "2" }, mt)
local r = {}
for i = 1, 400 do
  if i == 300 then
    mt.__index = function(_, k) return "m" end
    mt.__len = function() return 4 end
  end
  r[i] = table.concat(t, ",")
end
print("late mm concat", r[1], r[299], r[300], r[400])

local u = setmetatable({}, mt)
local mt2 = {}
local w = setmetatable({}, mt2)
local got = {}
for i = 1, 400 do
  if i == 300 then mt2.__newindex = function(tt, k, v) got[#got + 1] = k end end
  table.insert(w, i)
end
print("late newindex insert", #got, got[1], rawlen(w))
