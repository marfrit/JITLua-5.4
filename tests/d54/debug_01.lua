--! §4.2/§5.8 debug library 5.4: upvalueid/upvaluejoin, getinfo fields, hooks.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function mk()
  local a, b = 1, 2
  return function() return a + b end, function() return a end
end
local f, g = mk()
p("upvalueid type", type(debug.upvalueid(f, 1)))
p("upvalueid shared", debug.upvalueid(f, 1) == debug.upvalueid(g, 1))
p("upvalueid distinct", debug.upvalueid(f, 1) == debug.upvalueid(f, 2))
p("upvalueid oob", debug.upvalueid(f, 3), debug.upvalueid(f, 0), debug.upvalueid(f, -1))
p("upvalueid nonfunc", pcall(debug.upvalueid, 5, 1))
p("upvaluejoin", (function()
  local x, y = 10, 20
  local h1 = function() return x end
  local h2 = function() return y end
  debug.upvaluejoin(h1, 1, h2, 1)
  return h1()
end)())
p("upvaluejoin oob", pcall(debug.upvaluejoin, f, 9, g, 1))
p("getinfo fields", (function()
  local function h(a, b) return a + b end
  local i = debug.getinfo(h, "u")
  return i.nups, i.nparams, i.isvararg
end)())
p("getinfo what", (function()
  local i = debug.getinfo(print, "S")
  return i.what, i.source
end)())
p("getinfo name", (function()
  local function named() end
  local i = debug.getinfo(named, "n")
  return i.name, i.namewhat
end)())
p("getlocal", (function()
  local function h() local aa, bb = 1, 2 return debug.getlocal(1, 1), debug.getlocal(1, 2) end
  return h()
end)())
p("setlocal", (function()
  local function h() local aa = 1 debug.setlocal(1, 1, 9) return aa end
  return h()
end)())
p("getupvalue", (function()
  local u = 5
  local h = function() return u end
  local n, v = debug.getupvalue(h, 1)
  return n, v
end)())
p("setupvalue", (function()
  local u = 5
  local h = function() return u end
  debug.setupvalue(h, 1, 7)
  return h()
end)())
p("getmetatable", debug.getmetatable("") ~= nil, debug.getmetatable(5))
p("setmetatable", (function()
  local t = {}
  debug.setmetatable(t, { __index = function() return 42 end })
  return t.anything
end)())
p("traceback type", type(debug.traceback()))
p("sethook gethook", (function()
  local n = 0
  debug.sethook(function() n = n + 1 end, "c")
  local function h() end
  h()
  debug.sethook()
  return n > 0, type(debug.gethook())
end)())
p("hook count", (function() debug.sethook(function() end, "", 10) debug.sethook() return true end)())
