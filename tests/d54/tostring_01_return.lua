--! §6.4 __tostring must return a string (PUC 5.4 luaL_tolstring).
--! A metamethod that returns a number is converted by lua_tolstring; any other
--! non-string result raises "'__tostring' must return a string" at the point
--! of the conversion. Only the first of several results counts.
--! Paths: tostring(), print(), string.format("%s"), the method form, and the
--! error object kept by pcall. table.concat and the .. operator do not call
--! __tostring in 5.4 (they report the value type).
local function strip(e) return (tostring(e):gsub("^.-:%d+: ", "")) end
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
-- tostring() is part of what is under test here, so report through a local
-- view of it that cannot raise on the test's own labels.
local function ts(v)
  local ok, r = pcall(tostring, v)
  if ok and type(r) == "string" then return "TS-OK:" .. r end
  if ok then return "TS-BADTYPE:" .. type(r) end
  return "TS-ERR:" .. strip(r)
end
local function ret(v) return function() return v end end
local function mk(f) return setmetatable({}, { __tostring = f }) end
local cases = {
  { "str", mk(ret("S")) },
  { "num", mk(ret(42)) },
  { "num3", mk(ret(3.0)) },
  { "nil", mk(ret(nil)) },
  { "tab", mk(ret({})) },
  { "bool", mk(ret(true)) },
  { "two", mk(function() return "A", "B" end) },
  { "err", mk(function() error("E") end) },
}
for _, c in ipairs(cases) do
  local name, v = c[1], c[2]
  p("tostring", name, ts(v))
  local okf, rf = pcall(string.format, "%s", v)
  p("format", name, okf, okf and ("string:" .. rf) or strip(rf))
  local okm, rm = pcall(function() return ("%s"):format(v) end)
  p("format-method", name, okm, okm and ("string:" .. rm) or strip(rm))
  local okp, ep = pcall(print, v)
  p("print", name, okp, okp and "" or strip(ep))
  -- Not a __tostring path in 5.4: concat reports the value's type.
  local okc, rc = pcall(table.concat, { v }, ",")
  p("concat", name, okc, strip(rc))
  local oka, ra = pcall(function() return v .. "" end)
  p("concat-op", name, oka, strip(ra))
  -- pcall keeps the original error object; tostring on it follows the rule.
  local oke, ee = pcall(function() error(v) end)
  p("error-obj", name, oke, type(ee), ts(ee))
end
-- A hot loop through a well-formed __tostring keeps the conversion on every
-- path, and a loop through a number-returning one converts each result.
local sobj = mk(ret("hot"))
local nobj = mk(ret(42))
local bad = 0
for i = 1, 3000 do
  if tostring(sobj) ~= "hot" then bad = bad + 1 end
  local s = tostring(nobj)
  if type(s) ~= "string" or s ~= "42" then bad = bad + 1 end
end
p("hot loops", bad)
-- Under the JIT, one trace may record either kind; check both orders.
local n = 0
for i = 1, 3000 do n = n + #tostring((i % 2 == 0) and sobj or nobj) end
p("hot mixed", n)
