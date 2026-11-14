--! §4.2 environments: 5.4 has _ENV (no getfenv/setfenv in the std library).
--! LuaJIT keeps getfenv/setfenv as extensions (MISSION §3: extension wins).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("fenv ext", type(getfenv), type(setfenv))
p("_ENV", type(_ENV), _ENV ~= nil)
p("load env", (function()
  local env = { print = print, x = 7 }
  local f = assert(load("return x", "t", "t", env))
  return f()
end)())
p("load env isolated", (function()
  local f = assert(load("return type(print)", "t", "t", {}))
  return f()
end)())
p("load mode", (function() local f, e = load("return 1", "t", "b") return f == nil, type(e) end)())
p("setfenv ext", (function()
  if not setfenv then return "absent" end
  local f = load("return x")
  setfenv(f, { x = 9 })
  return f()
end)())
p("global write", (function() _G.zz_test = 1 local v = zz_test _G.zz_test = nil return v end)())
p("module env", (function()
  local f = assert(load("local M = {} function M.get() return 42 end return M", "t", "t", {}))
  return f().get()
end)())
