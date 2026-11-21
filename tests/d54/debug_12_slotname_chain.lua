--! §4.6 operand names for long field chains. PUC's isEnv (ldebug.c) looks at
--! the indexed table with basicgetobjname, which follows locals, upvalues,
--! moves and constants but not table reads, so naming the callee of
--! t.a.a...a.c() costs one scan. This tree named the table with the full
--! slot-name search, which recursed once per TGETS link (a C-stack overflow
--! at about 100000 links) and rescanned the jumps from the start at every
--! step. Printed: the error messages of long chains, and names that pass
--! through the same code (_ENV locals/upvalues, keys, methods) in a loop.
local function msg(src, ...)
  local f, e = load(src)
  if f then local ok; ok, e = pcall(f, ...) end
  return (tostring(e):gsub("^[^:]*:%d+: ", ""))
end
local t = {}; t.a = t
for _, n in ipairs({10, 1000, 100000}) do
  print(n, msg("local t = ... local x = t" .. string.rep(".a", n) .. ".c()", t))
  print(n, msg("local t = ... return t" .. string.rep(".a", n) .. ".c.d", t))
  print(n, msg("local t = ... t" .. string.rep(".a", n) .. ":m()", t))
  print(n, msg("local t = ... return t" .. string.rep("[\"a\"]", n) .. " + 1", t))
end
print(msg("local _ENV = {a = {}} return a.b.c"))
print(msg("local _ENV = {} return x + 1"))
print(msg("local e = _ENV return e.nope()"))
print(msg("return (function() return undefinedglobal.x end)()"))
print(msg("local t = {} local k = 'key' return t[k].z"))
print(msg("local t = {} return t[{}].z"))
print(msg("local t, u = {}, {} local x = t.a or u.b return x.y"))
-- The same names from code that runs hot under -jon.
local env = setmetatable({}, {__index = function() return nil end})
local f = load("local t = ... return t.a.a.a.b.c", "=chain", "t", env)
local g = load("return gx.y", "=g", "t", env)
local last1, last2
for _ = 1, 100 do
  last1 = select(2, pcall(f, t))
  last2 = select(2, pcall(g))
end
print(last1)
print(last2)
