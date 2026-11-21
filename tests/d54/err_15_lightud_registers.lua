--! Two messages PUC's errors.lua reads (lines 237 and 652-661). An argument
--! error on a light userdata says "got light userdata" (lauxlib.c
--! luaL_typeerror, unless a metatable for light userdata has a __name);
--! operand errors still say "userdata" (luaT_objtypename). A function or
--! expression that needs more registers than a frame has fails with
--! "function or expression needs too many registers" (lcode.c
--! luaK_checkstack). This tree said "got userdata" and "function or
--! expression too complex". Its frame has 250 slots, PUC's 255: the call
--! below needs more than either. Printed: the messages without positions.
local function msg (f, ...)
  local ok, e = pcall(f, ...)
  print(ok, (tostring(e):gsub("^[^:]*:%d+: ", "")))
end
local lud = debug.upvalueid(function () return msg end, 1)
print(type(lud))
msg(debug.setuservalue, lud, {})
msg(string.rep, lud, 2)
msg(math.sin, lud)
msg(setmetatable, lud, {})
msg(function () return lud + 1 end)
msg(function () return #lud end)
msg(function () return lud.x end)
debug.setmetatable(lud, {__name = "LUD"})
msg(string.rep, lud, 2)
msg(function () return lud + 1 end)
debug.setmetatable(lud, nil)
msg(string.rep, lud, 2)

local function load1 (s)
  local f, e = load(s, "=x")
  print(f and "loaded" or e)
end
load1("a = f(x" .. string.rep(",x", 260) .. ")")
load1("local t = {" .. string.rep("x,", 300) .. "}")
-- Nested calls: refused on both sides, with "too many" or "overflow".
local f, e = load("local function a (x) return x end; return " ..
                  string.rep("a(", 500))
print(f == nil, (string.find(e, "too many") or string.find(e, "overflow")) ~= nil)
