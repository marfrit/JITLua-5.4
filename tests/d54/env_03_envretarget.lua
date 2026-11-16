-- 5.4 _ENV: lexical via local/parameter, implicit via the function env.
-- LuaJIT model: implicit retarget is function-scoped (shared-upvalue corner
-- case documented), traces are flushed on retarget.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
-- Lexical: local _ENV routes free names through the table.
p("local env", (function()
  local _ENV = {p = p, x = 1}
  p("in", x)
  do local _ENV = {p = p, x = 2}; p("block", x) end
  p("after", x)
  return x
end)())
-- Parameter _ENV.
local function withenv(_ENV) return p, v end
local pp, vv = withenv({p = p, v = 5})
p("param env", pp == p, vv)
-- Implicit: chunk _ENV retarget, reads via __index back to _G.
p("implicit", (function()
  _ENV = setmetatable({}, {__index = _G})
  q_test_value = 11
  local got = q_test_value
  q_test_value = nil
  return got
end)())
-- _ENV read returns the current environment.
p("env read", (function() _ENV = {p = p, mark = 3}; return _ENV.mark, _ENV == nil end)())
-- JIT guard: a hot loop reading a global, retargeted mid-loop.
p("jit retarget", (function()
  local t1 = {p = p, v = 1}
  local t2 = {p = p, v = 2}
  _ENV = t1
  local last = 0
  for i = 1, 100000 do
    last = v
    if i == 50000 then _ENV = t2 end
    if i > 50000 and last ~= 2 then return "wrong@" .. i end
  end
  return last
end)())
-- load(..., env) keeps setting the function env; _ENV reads it.
p("load env", (function()
  local env = {p = p, type = type, x = 7}
  local f = assert(load("return x, type(_ENV)", "c", "t", env))
  return f()
end)())
