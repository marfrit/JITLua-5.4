--! §4.2 error(level), non-string error objects, xpcall/pcall semantics
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function strip(e) return (tostring(e):gsub("^.-:%d+: ", "")) end
p("error str", pcall(function() error("msg") end))
p("error level0", (function() local ok, e = pcall(function() error("msg", 0) end) return ok, e end)())
p("error level2", (function()
  local function inner() error("msg", 2) end
  local ok, e = pcall(inner)
  return ok, strip(e)
end)())
p("error table", (function() local ok, e = pcall(function() error({ code = 1 }) end) return ok, type(e), e.code end)())
p("error nil", (function() local ok, e = pcall(function() error() end) return ok, tostring(e) end)())
p("error number", (function() local ok, e = pcall(function() error(42) end) return ok, e end)())
p("xpcall str", xpcall(function() error("x") end, function(e) return "handled:" .. strip(e) end))
p("xpcall table", xpcall(function() error({ 1 }) end, function(e) return type(e) end))
p("xpcall handler err", pcall(xpcall, function() error("a") end, function() error("b") end))
p("xpcall args", xpcall(function(a, b) return a + b end, print, 1, 2))
p("pcall multi", pcall(function() return 1, 2, 3 end))
p("pcall yield", (function()
  local co = coroutine.create(function() pcall(function() coroutine.yield(1) end) end)
  return coroutine.resume(co)
end)())
p("assert msg", pcall(function() assert(false, "custom") end))
p("assert table", (function() local ok, e = pcall(function() assert(nil, { 1 }) end) return ok, type(e) end)())
p("error in mm", strip((select(2, pcall(function()
  return setmetatable({}, { __add = function() error("inmm") end }) + 1
end)))))
p("tostring err obj", (function()
  local ok, e = pcall(function() error(setmetatable({}, { __tostring = function() return "T" end })) end)
  return ok, tostring(e)
end)())
p("level beyond stack", (function() local ok, e = pcall(function() error("m", 99) end) return ok, strip(e) end)())
