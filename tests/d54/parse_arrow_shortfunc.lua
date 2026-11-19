--! PUC divergence (inherited LuaJIT extension): the backported v3.0 "Short
--! Function Expression" (`a -> b`, `|x| -> x*x`) is accepted by LuaJIT-family
--! interpreters; PUC 5.4.9 rejects it. Downstream lume 2.3.0's lambda test
--! expects the rejection (docs/notes/downstream-2026-11.md). Mode B and R
--! agree (both arms are the same interpreter).
--! modes: A
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local ok1, f1 = pcall(load, "return a->b")
p("shortfunc", ok1, type(f1))

local ok2, f2 = pcall(load, "return |x| -> x*x")
p("shortfunc_params", ok2, type(f2))

local ok3, f3 = pcall(load, "return function(a,b) return a->b end")
p("shortfunc_wrapped", ok3, type(f3))

local ok4, f4 = pcall(load, "return 1->2")
p("shortfunc_number", ok4, type(f4))

p("plain_load", pcall(load, "return 1 + 2") == true)
