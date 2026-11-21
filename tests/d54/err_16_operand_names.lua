--! 5.4 operand names that PUC's errors.lua checks (lines 176, 190, 191,
--! 301). A name read through a local or an upvalue named _ENV is a global
--! (ldebug.c isEnv), also with a key past the constant operand
--! (OP_GETTABLE); a method call on it stays a method. A register whose last
--! write lies inside the range of an earlier forward jump that lands at or
--! before the faulting instruction has no name (ldebug.c findsetreg,
--! jmptarget/filterpc): (a or b)() and (a or a)+(a and a). Names after a
--! finished if, inside loops and through locals stay. This tree named the
--! _ENV accesses "field" and kept the name of a conditionally written
--! operand. Printed: the messages without positions.
local function msg (src)
  local f, e = load(src)
  if f then local ok; ok, e = pcall(f) end
  print((tostring(e):gsub("^[^:]*:%d+: ", "")))
end
-- _ENV as a local or upvalue.
msg("local _ENV = {x = {}}; a = a + 1")
msg("local _ENV = {x = {}}; x.y.z = 1")
msg("local _ENV = {}; f()")
msg("local _ENV = {}; return (function () return y + 1 end)()")
msg("local _ENV = {}; return (function () g() end)()")
msg("local _ENV = {m = {}}; m:k()")
msg("local _ENV = {}; local e = _ENV; e.x()")
msg("local t = _ENV; t.zzz()")
msg("local _ENV = {} do local _ENV = {}; q() end")
msg("local _ENV = _ENV; aaa = bbb + 1")
msg("local _ENV = setmetatable({}, {__index = _G}); return #nope")
do  -- keys past the constant operand
  local t = {}
  for i = 1, 1000 do t[i] = "aaa = x" .. i end
  local s = table.concat(t, "; ")
  msg(s .. "; aaa = bbb + 1")
  msg("local _ENV = _ENV;" .. s .. "; aaa = bbb + 1")
  msg("local _ENV = _ENV;" .. s .. "; bbb()")
  msg(s .. "; local t = {}; aaa = t.bbb + 1")
  msg(s .. "; local t = {}; t:bbb()")
end
-- Conditionally written operands.
msg("aaa = {}; x = (aaa or aaa) + (aaa and aaa)")
msg("aaa = {}; (aaa or aaa)()")
msg("local f, g; (f or g)()")
msg("local a, b = {}, nil; return (b or a) + 1")
msg("local a; return (a and a.x)()")
msg("local t = {}; return (t.x or t.y)()")
msg("local c; return (c and 1 or nil) .. 'x'")
msg("aaa = 1; local aaa, bbbb = 2, 3; aaa = math.sin(1) and bbbb(3)")
msg("aaa = 1; local aaa, bbbb = 2, 3; aaa = bbbb(1) or aaa(3)")
msg("local a, b, c, f = 1, 1, 1; f((a and b) or c)")
msg("local a, b, c = 1, 1, 1; ((a and b) or c)()")
-- Names that stay.
msg("local x; if x then x = 1 end; return x.y")
msg("local c; if c then c = 2 end; t.u.v = 1")
msg("for i = 1, 2 do local z = nofunc; z() end")
msg("while true do noglob.x = 1 end")
msg("local t = {}; for i = 1, 2 do t.a.b = i end")
msg("local t = {}; repeat local v = t.k; v() until true")
msg("local u = {}; local f = function () return u.v.w end; return f()")
msg("local a = {}; if a then return a.b.c end")
msg("local a = nil; local b = a or {}; return b.x.y")
