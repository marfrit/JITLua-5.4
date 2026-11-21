--! §meta an __eq that cannot be called: PUC names the metamethod in the
--! error, with the position ("attempt to call a boolean value (metamethod
--! 'eq')"), like every other metamethod. Interpreter and compiled code.
local function msg(f, ...)
  local ok, e = pcall(f, ...)
  return tostring(ok) .. " " .. tostring(e)
end
local function eq(a, b) return a == b end
local function ne(a, b) return a ~= b end
local F = setmetatable({}, {__eq = false})
local N = setmetatable({}, {__eq = 42})
local S = setmetatable({}, {__eq = "str"})
local T = setmetatable({}, {__eq = {}})
local C = setmetatable({}, {__eq = setmetatable({}, {__call = function() return true end})})
local plain = {}
for _, o in ipairs{F, N, S, T, C} do
  local r1, r2, r3
  for i = 1, 100 do r1 = msg(eq, o, plain); r2 = msg(ne, plain, o); r3 = msg(eq, o, o) end
  print(r1) print(r2) print(r3)
end
-- inline, with a line of its own
print(pcall(function()
  return F == plain
end))
-- a loop compiled for a callable __eq meets one that is not
local mt = {__eq = function() return true end}
local x, y = setmetatable({}, mt), setmetatable({}, mt)
local n = 0
for i = 1, 300 do
  if i == 250 then mt.__eq = false end
  local ok, e = pcall(eq, x, y)
  if ok then n = n + 1 else n = n + 1000 end
  if i == 300 then print(n, e) end
end
