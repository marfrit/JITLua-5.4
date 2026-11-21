--! §4.2 table.insert(t, v) and table.remove(t) in compiled code. A push
--! reads no element and a pop of a non-empty table reads and clears the
--! border element, so PUC's lua_seti/lua_geti are raw there whatever
--! __index says (class instances); __newindex (push) and __len (both) select
--! the metamethod path. The marked loops must compile: an aborted or
--! stitched trace fails the test (table.insert on an object with a metatable used to abort the
--! trace). Differential against PUC 5.4.9 and -joff vs -jon.
local jit = rawget(_G, "jit")
local aborts, watching = 0, false
if jit and jit.status and jit.status() and jit.attach then
  local ok, util = pcall(require, "jit.util")
  local root = {}  -- only root traces: a side trace may run on into print
  jit.attach(function(what, tr, func, pc, otr)
    if what == "start" then
      root[tr] = watching and otr == nil
    elseif root[tr] and what == "abort" then
      aborts = aborts + 1
    elseif root[tr] and what == "stop" and ok and
	   util.traceinfo(tr).linktype == "stitch" then
      aborts = aborts + 1  -- the call was left to the interpreter
    end
  end, "trace")
end

local C = {} C.__index = C
function C.method() return "m" end

watching = true
do
  local o = setmetatable({}, C)
  for i = 1, 1000 do table.insert(o, i) end
  print("push obj", #o, o[1], o[1000], rawget(o, 1001), o.method())
  local s = 0
  for i = 1, 1000 do s = s + table.remove(o) end
  print("pop obj", s, #o)
  local p = {}
  for i = 1, 1000 do table.insert(p, i * 2) end
  s = 0
  for i = 1, 1000 do s = s + table.remove(p) end
  print("push/pop plain", s, #p)
  local st, n = {}, 0
  for i = 1, 1000 do
    table.insert(st, i) table.insert(st, i + 0.5)
    n = n + table.remove(st) + table.remove(st)
  end
  print("stack", n, #st)
  local q = {}
  for i = 1, 500 do q[i] = i end
  for i = 1, 400 do table.remove(q) end  -- result unused
  print("pop unused", #q, q[100], q[101])
end
watching = false

-- an index function: a pop does not call it while elements exist, the pop
-- of the empty table does (t[0])
local calls = 0
local I = setmetatable({}, {__index = function(_, k) calls = calls + 1 return "idx" .. tostring(k) end})
for i = 1, 300 do I[i] = i end
local last
for i = 1, 302 do last = table.remove(I) end
print("index fn", calls, last, #I)

-- __newindex: a push goes through it, a pop of existing elements does not
local nw = 0
local N = setmetatable({}, {__newindex = function(t, k, v) nw = nw + 1 rawset(t, k, v) end})
for i = 1, 300 do table.insert(N, i) end
local sn = 0
for i = 1, 300 do sn = sn + table.remove(N) end
print("newindex", nw, sn, #N)

-- __len
local L = setmetatable({1, 2, 3, 4, 5}, {__len = function() return 2 end})
local got = {}
for i = 1, 100 do table.insert(L, "x") got[#got + 1] = tostring(table.remove(L)) end
print("len", got[1], got[100], rawlen(L), L[3])

-- the metatable gains __newindex / __len while the loop is compiled
local mt = {__index = C}
local g = setmetatable({}, mt)
local log = 0
for i = 1, 600 do
  if i == 400 then mt.__newindex = function(t, k, v) log = log + 1 rawset(t, k, v) end end
  if i == 500 then mt.__len = function(t) return rawlen(t) - 1 end end
  table.insert(g, i)
end
print("gain push", rawlen(g), log, g[#g + 1], g[400], g[500], g[rawlen(g)])
local h = setmetatable({}, mt)
mt.__newindex, mt.__len = nil, nil
for i = 1, 600 do rawset(h, i, i) end
local acc = 0
for i = 1, 500 do
  if i == 300 then mt.__len = function(t) return 3 end end
  acc = acc + (table.remove(h) or 0)
end
print("gain pop", acc, rawlen(h), h[3], h[4])
mt.__len = nil

-- one call site, plain tables first, then objects, proxies, empty tables
local function proxy()
  local store = {}
  return setmetatable({}, {__index = function(_, k) return store[k] end,
    __newindex = function(_, k, v) store[k] = v end, __len = function() return #store end}), store
end
local list = {}
for i = 1, 400 do
  if i <= 250 then list[i] = {1, 2}
  elseif i <= 300 then list[i] = setmetatable({1, 2}, C)
  elseif i <= 350 then list[i] = proxy()
  else list[i] = {} end
end
local r = {}
for i = 1, 400 do
  local t = list[i]
  table.insert(t, i)
  local a = table.remove(t)
  local b = table.remove(t)
  local c = table.remove(t)
  local d = table.remove(t)
  r[i] = tostring(a) .. tostring(b) .. tostring(c) .. tostring(d)
end
print(r[1], r[250], r[251], r[300], r[301], r[350], r[351], r[400])
-- positions and errors stay with the library
local e = {1, 2, 3}
for i = 1, 100 do table.insert(e, 1, 0) table.remove(e, 1) end
print(#e, table.remove(e, 2), table.remove(e, #e + 1), pcall(table.remove, e, 7))
print(table.remove({}), table.remove({[0] = "z"}), pcall(table.remove, 5), pcall(table.insert, {}, 1, 2, 3))
if aborts > 0 then error("aborted or stitched traces in the loops that must compile: " .. aborts) end
