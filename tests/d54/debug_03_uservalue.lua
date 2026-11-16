---! 5.4 debug.getuservalue(u, n) / debug.setuservalue(u, v, n): the n-th user
---! value plus true, or fail (nil) for a non-userdata or an index outside the
---! user values; setuservalue returns the userdata or fail; the argument
---! checks. Lua code cannot create userdata with user values (that is the C
---! API, tests/capi), so the observable surface here is io's file handles,
---! which have none, like PUC's. Mode A compares with PUC, mode B the JIT with
---! the interpreter.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(label, table.concat(t, " "))
end
local f = io.stdin
p("get default", debug.getuservalue(f))
p("get 1", debug.getuservalue(f, 1))
p("get 10", debug.getuservalue(f, 10))
p("get 0", debug.getuservalue(f, 0))
p("get nonud", debug.getuservalue(42))
p("get nonud2", debug.getuservalue("x", 1))
p("set default", debug.setuservalue(f, 10) == nil)
p("set 10", debug.setuservalue(f, 10, 10) == nil)
p("set 0", debug.setuservalue(f, 10, 0) == nil)
p("set nonud", pcall(debug.setuservalue, 42, 1))
p("set noval", pcall(debug.setuservalue, f))
p("set badn", pcall(debug.setuservalue, f, 1, "x"))
p("get badn", pcall(debug.getuservalue, f, "x"))
for i = 1, 200 do
  local a, b = debug.getuservalue(f, i % 3)
  if a ~= nil or b ~= nil then p("loop", i, a, b) end
end
p("loop done")
