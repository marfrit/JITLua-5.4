--! Method-call micro-benchmark: class-as-metatable with obj:method() in a hot
--! loop. A trace that indexes a table operand guards that table's metatable
--! (and its __mode) at runtime, so this isolates the guard's cost. Prints
--! "METHOD <name> <ms> <checksum>"; METHOD_N overrides the iteration count.
--! Plain Lua 5.4 (and stock 2.1) so every arm can run it.
local N = tonumber(os.getenv("METHOD_N") or "20000000")

local Class = {}
Class.__index = Class
function Class:get() return self.x end

local function time(name, f)
  collectgarbage("collect")
  local t0 = os.clock()
  local s = f()
  print(string.format("METHOD %-10s %8.1f %d", name, (os.clock() - t0) * 1000, s))
end

-- A table with no metatable: the guard is "metatable == NULL".
local plain = {x = 1}
time("plain", function()
  local s, o = 0, plain
  for i = 1, N do s = s + o.x end
  return s
end)

-- One fixed receiver of a class: the metatable load is loop-invariant.
local one = setmetatable({x = 1}, Class)
time("field", function()
  local s, o = 0, one
  for i = 1, N do s = s + o.x end
  return s
end)
time("fixed", function()
  local s, o = 0, one
  for i = 1, N do s = s + o:get() end
  return s
end)

-- Rotating receivers sharing one metatable: the load varies, the metatable
-- (and so the guard's constant) does not.
local objs = {}
for i = 1, 8 do objs[i] = setmetatable({x = i}, Class) end
time("rotating", function()
  local s, o = 0, objs
  for i = 1, N do s = s + o[(i & 7) + 1]:get() end
  return s
end)

-- Each receiver with its own metatable: the guard's constant differs per
-- object, so this is the worst case for a shared-invariant guard.
local own = {}
for i = 1, 8 do own[i] = setmetatable({x = i}, {__index = {get = Class.get}}) end
time("ownmt", function()
  local s, o = 0, own
  for i = 1, N do s = s + o[(i & 7) + 1]:get() end
  return s
end)
