--! §load a chunk may hold any number of functions: the parser keeps nothing
--! on the Lua stack per parsed function (it used to leave one slot each, so
--! a chunk with about 65000 functions ended in "stack overflow"), and load
--! works the same from a coroutine and from deep recursion. The functions
--! are spread over several enclosing functions: one function holds at most
--! 65536 constants here (docs/DIFFERENCES.md). Differential against PUC
--! 5.4.9.
local function try(label, src)
  local f, e = load(src)
  print(label, f ~= nil, e and (tostring(e):match("^[^\n]*")))
  return f
end
local function group(n)  -- one function that holds n functions
  return "function() return {" .. string.rep("function() end,", n) .. "} end,"
end
-- 23000 and 69000 functions: the second is past the old limit. (Sized for
-- the sanitizer builds, where this parsing is far slower.)
for _, groups in ipairs{1, 3} do
  local f = try("groups " .. groups, "return {" .. string.rep(group(23000), groups) .. "}")
  local n = 0
  if f then for _, g in ipairs(f()) do n = n + #g() end end
  print("functions", n)
end
try("stmts", "local function w()\n" .. string.rep("x = function() end\n", 2000) .. "end\n")
-- nested functions, each level one more closure
local depth = 60
local f = try("nested", string.rep("return function() ", depth) .. "return 1" ..
			string.rep(" end", depth))
local v = f
for i = 1, depth + 1 do v = v() end
print("nested value", v)
-- from a coroutine and from deep recursion
print(coroutine.wrap(function()
  return load(string.rep("x = function() end\n", 3000)) ~= nil
end)())
local function deep(n)
  if n == 0 then return load(string.rep("x = function() end\n", 1000)) ~= nil end
  return (deep(n - 1))
end
print(deep(150))
-- a reader function is called with a usable stack
local parts, i = {}, 0
for k = 1, 500 do parts[k] = "y = function() return " .. k .. " end\n" end
local g = load(function() i = i + 1 return parts[i] end)
print(g ~= nil, i)
g() print(y())
