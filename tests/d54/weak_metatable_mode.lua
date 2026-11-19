--! modes: B,R
--! A class metatable (__index chain) that gains __mode after the method-call
--! loop was compiled must exit and re-specialize, or the weak entry the loop
--! reads stays alive. Covers a raw store, the TSETS fast path, a setmetatable
--! swap, and a metatable shared by several objects. The loop body calls a
--! method through __index so the metaobject guard path is exercised too.
--! Fails (bounded, no hang) if the weakness guard misses the change.
local jit = rawget(_G, "jit")
local Keep                        -- keeps the method function strongly alive

local function spin(x, LIMIT)
  local n = 0
  while x[1] and n < LIMIT do
    local _ = x:get()             -- method call through the class __index
    local a = ("garbage"):rep(8)
    n = n + 1
  end
  return n
end

local function mkclass()
  local Class = {}
  Class.__index = Class
  Class.get = function(self) return 1 end
  Keep = Class.get
  return Class
end

local function run(label, mutate)
  if jit then jit.flush() end
  local Class = mkclass()
  local x = setmetatable({[1] = {}}, Class)
  spin(x, 2000)                   -- compile while Class has no __mode
  mutate(Class, x)
  local n = spin(x, 20000)
  assert(x[1] == nil, label .. ": weak entry not collected (n=" .. n .. ")")
  print(label .. ": ok")
end

run("rawset", function(Class) rawset(Class, "__mode", "kv") end)
run("tsets", function(Class) Class.__mode = "kv" end)
run("setmt", function(Class, x)
  setmetatable(x, {__index = Class, __mode = "kv"})
end)
run("shared", function(Class, x)
  local y = setmetatable({[1] = {}}, Class)  -- a second object shares Class
  y:get()
  rawset(Class, "__mode", "kv")
end)
print("ok")
