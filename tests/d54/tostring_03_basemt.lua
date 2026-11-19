--! §6.4 __tostring in the metatable of a basic type: 5.4 keeps one metatable
--! per type, so a method installed with debug.setmetatable (or on the string
--! metatable reachable through getmetatable("")) applies to every value of the
--! type on every conversion path. print() itself uses luaL_tolstring and does
--! not call a replaced global tostring (5.4.9 luaB_print).
local function strip(e) return (tostring(e):gsub("^.-:%d+: ", "")) end
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function ts(v)
  local ok, r = pcall(tostring, v)
  if ok and type(r) == "string" then return "TS-OK:" .. r end
  if ok then return "TS-BADTYPE:" .. type(r) end
  return "TS-ERR:" .. strip(r)
end
-- String base metatable: a hot path in the interpreter and in compiled code.
local smt = getmetatable("")
smt.__tostring = function() return "STR-MM" end
p("tostring string mt", ts("abc"))
p("format string mt", string.format("%s", "abc"))
p("print string mt", pcall(print, "abc"))
local n = 0
for i = 1, 3000 do n = n + #tostring("abc") end
p("hot string mt", n)
smt.__tostring = nil
p("tostring string after", ts("abc"))
-- Number base metatable: the method may return a number (converted) or a
-- non-string (raised) on every path.
debug.setmetatable(1, { __tostring = function() return 2 end })
p("tostring number mt", ts(7))
p("format number mt", string.format("%s", 7))
p("print number mt", pcall(print, 7))
n = 0
for i = 1, 3000 do n = n + #tostring(i) end
p("hot number mt", n)
debug.setmetatable(1, { __tostring = function() return nil end })
p("tostring number bad", ts(7))
p("format number bad", pcall(string.format, "%s", 7))
debug.setmetatable(1, nil)
p("tostring number plain", ts(7))
-- Boolean base metatable shares one entry for true and false in 5.4.
debug.setmetatable(true, { __tostring = function() return "BOOL-MM" end })
p("tostring bool mt", ts(true))
p("tostring false mt", ts(false))
p("format bool mt", string.format("%s", true))
debug.setmetatable(true, nil)
p("tostring bool plain", ts(true))
-- Function base metatable with a metamethod.
local f = function() end
debug.setmetatable(f, { __tostring = function() return "FN-MM" end })
p("tostring function mt", ts(f))
p("format function mt", string.format("%s", f))
debug.setmetatable(f, nil)
-- print() must not consult a replaced global tostring.
local real = tostring
_G.tostring = function() return "REPLACED" end
local okp = pcall(print, 12345)
p("print replaced", okp)
_G.tostring = real
-- A replaced global tostring still affects tostring() itself, as in PUC.
local okt, rt = pcall(tostring, 12345)
p("tostring replaced", okt, rt)
_G.tostring = real
p("tostring restored", ts(12345))
