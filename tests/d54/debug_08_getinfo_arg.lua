--! §5 debug.getinfo: a function is checked first, otherwise the argument is a
--! strict luaL_checkinteger level, so a table says "number expected, got
--! table" and 1.5 says "number has no integer representation". Differential
--! against PUC 5.4.9.
local function norm(e)
  local s = tostring(e)
  return s:gsub("^.-:%d+: ", "")
end
local function q(label, ...)
  local ok, a = pcall(debug.getinfo, ...)
  if ok and type(a) == "table" then a = "table:" .. tostring(a.what) end
  print(label .. " | ok=" .. tostring(ok) .. " | " ..
	(ok and tostring(a) or norm(a)))
end
local function f() return 1 end
q("function", f)
q("table", {})
q("float level", 1.5)
q("string level", "1")
q("nil level", nil)
q("true level", true)
q("level 0", 0)
q("level 1", 1)
q("level 999", 999)
