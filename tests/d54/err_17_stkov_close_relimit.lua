--! modes: A,B
--! timeout: 120
-- A Lua stack overflow whose unwinding runs <close> handlers (the 5.4 error
-- path chain of pcall/xpcall) must leave the stack at its normal limit once
-- the handlers are done (PUC 5.4.9 ldo.c luaD_shrinkstack after the error,
-- lfunc.c luaF_close). Otherwise the next overflow starts from the enlarged
-- error stack: it is reported as "error in error handling" instead of
-- "stack overflow", later recursions go deeper, and <close> handlers of the
-- deeper levels are refused.
-- Prints messages without their position and booleans: the depth itself is
-- an implementation limit and differs by design (docs/DIFFERENCES.md).

local function strip(m) return (tostring(m):gsub("^.-:%d+: ", "")) end

local made, closed = 0, 0
local mt = {__close = function() closed = closed + 1 end}
local depth = 0
local function rec(n)
  local x <close> = setmetatable({}, mt)
  made = made + 1
  if n > depth then depth = n end
  return rec(n + 1) + 1
end
local plaindepth = 0
local function rec2(n)
  if n > plaindepth then plaindepth = n end
  return rec2(n + 1) + 1
end

local depths, pdepths = {}, {}
for k = 1, 6 do
  depth, plaindepth = 0, 0
  local ok, e = pcall(rec, 1)
  print("close", k, ok, strip(e), made == closed)
  depths[k] = depth
  local ok2, e2 = pcall(rec2, 1)
  print("plain", k, ok2, strip(e2))
  pdepths[k] = plaindepth
  local ok3, e3 = xpcall(rec2, function(m) return "H:" .. strip(m) end, 1)
  print("xpcall", k, ok3, e3)
  local ok4, e4 = xpcall(rec, function(m) return "H:" .. strip(m) end, 1)
  print("xpcall close", k, ok4, e4, made == closed)
end
local same, psame = true, true
for k = 2, 6 do
  if depths[k] ~= depths[1] then same = false end
  if pdepths[k] ~= pdepths[1] then psame = false end
end
print("same depth", same, psame)
print("all closed", made == closed)

-- The same through a coroutine and through a nested pcall level.
local co = coroutine.wrap(function()
  local ok, e = pcall(rec, 1)
  local ok2, e2 = pcall(rec2, 1)
  return strip(e) .. " / " .. strip(e2)
end)
print("coroutine", co(), made == closed)
print("nested", pcall(function()
  local ok, e = pcall(rec, 1)
  local ok2, e2 = pcall(rec2, 1)
  return strip(e) .. " / " .. strip(e2)
end))
print("final", made == closed)
