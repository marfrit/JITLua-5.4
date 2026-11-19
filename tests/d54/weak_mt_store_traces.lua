--! A string-keyed store into a table that is also a metatable must not throw
--! the traces that index its instances out of compiled code. The class idiom
--! (Class.__index = Class, a static field written from cold code) and a
--! variable string key stored into the metatable inside the loop: both stay
--! strong, so the guard on __mode must keep passing. Checked by the number of
--! traces the JIT needs (a guard that keeps failing compiles a new side trace
--! per store); the printed values are compared between the arms.

local jit = rawget(_G, "jit")
local jutil
if jit and jit.status() then
  local ok, m = pcall(require, "jit.util")
  if ok then jutil = m end
end

local function ntraces()
  local n = 0
  if jutil then
    for i = 1, 4000 do
      if jutil.traceinfo(i) then n = n + 1 end
    end
  end
  return n
end

-- 1. Class idiom, cold interpreted store on the class table.
local Class = {}
Class.__index = Class
function Class.get(self) return self.v end
local objs = {}
for i = 1, 64 do objs[i] = setmetatable({v = i}, Class) end
local function cold(i) Class.last = i end
if jit then jit.off(cold) end

local function calls(N, every)
  local s = 0
  for i = 1, N do
    local o = objs[(i & 63) + 1]
    s = s + o.v + o:get()
    if i % every == 0 then cold(i) end
  end
  return s
end

if jit then jit.flush() end
print("class", calls(400000, 500), Class.last)
local n1 = ntraces()
assert(n1 < 40, "class idiom: " .. n1 .. " traces, the __mode guard keeps failing")

-- 2. Variable string key stored into the metatable inside the compiled loop.
local mt = {}
mt.__index = mt
local o = setmetatable({x = 1}, mt)
local keys = {"a", "b", "c", "d"}
local function dyn(N)
  local s = 0
  for i = 1, N do
    mt[keys[(i & 3) + 1]] = i
    s = s + o.x
  end
  return s
end

if jit then jit.flush() end
print("dynkey", dyn(200000), mt.a, mt.d)
local n2 = ntraces()
assert(n2 < 40, "variable key: " .. n2 .. " traces, the __mode guard keeps failing")
print("ok")
