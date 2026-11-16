---! 5.4 _ENV as a visible upvalue: debug.getupvalue names and positions
---! (main chunk: always upvalue 1; other functions: at the place of the first
---! global access in upvalue-creation order, also when only a nested function
---! touches globals; none for functions that use no globals), getinfo nups,
---! setupvalue/upvaluejoin on _ENV (the Penlight/Sergey Rozhenko setfenv
---! idiom), upvalueid, and a string.dump round trip. Mode A compares with
---! PUC, mode B the JIT with the interpreter (mode R the dump/reload).
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(label, table.concat(t, " "))
end
local function uvnames(f)
  local r = {}
  for i = 1, 10 do
    local name = debug.getupvalue(f, i)
    if not name then break end
    r[#r+1] = name
  end
  return table.concat(r, ",")
end
local chunk = load("return x")
p("main", uvnames(chunk), debug.getinfo(chunk, "u").nups)
local a, b = 1, 2
local function g1() return a + y end          -- a first, then _ENV
local function g2() return y + a end          -- _ENV first
local function g3() return a + b end          -- no _ENV
local function g4() return function() return z end end  -- only the child
local function g5() return a, function() return b + w end end
p("g1", uvnames(g1), debug.getinfo(g1, "u").nups)
p("g2", uvnames(g2), debug.getinfo(g2, "u").nups)
p("g3", uvnames(g3), debug.getinfo(g3, "u").nups)
p("g4", uvnames(g4), uvnames(g4()), debug.getinfo(g4, "u").nups)
p("g5", uvnames(g5), uvnames((select(2, g5()))))
-- values: _ENV is the global table, real upvalues keep their values
local n1, v1 = debug.getupvalue(g1, 1)
local n2, v2 = debug.getupvalue(g1, 2)
p("values", n1, v1, n2, v2 == _G)
-- setupvalue on _ENV: a new environment for one closure
local env = setmetatable({y = 40}, {__index = _G})
p("set", debug.setupvalue(g1, 2, env), g1(), g2())
p("set2", debug.setupvalue(g2, 1, env), g2())
-- the setfenv idiom (Penlight compat): unique upvalue, then set
local function setfenv(f, t)
  local name, up = nil, 0
  repeat up = up + 1; name = debug.getupvalue(f, up) until name == "_ENV" or name == nil
  if name then
    debug.upvaluejoin(f, up, function() return name end, 1)
    debug.setupvalue(f, up, t)
  end
  return f
end
local function getfenv(f)
  local name, val, up = nil, nil, 0
  repeat up = up + 1; name, val = debug.getupvalue(f, up) until name == "_ENV" or name == nil
  return val
end
local function h() return X + Y end
setfenv(h, {X = 1, Y = 2})
p("setfenv", h(), getfenv(h).X, getfenv(g3))
-- upvalueid: two closures of one chunk share _ENV's identity, real upvalues differ per closure
local mk = load("local u = ... return function() return u, v end, function() return v end")
local c1, c2 = mk(1)
local d1, d2 = mk(2)
p("ids", debug.upvalueid(c1, 2) == debug.upvalueid(c2, 1), debug.upvalueid(c1, 1) == debug.upvalueid(d1, 1),
  debug.upvalueid(c1, 2) == debug.upvalueid(d1, 2), debug.upvalueid(g3, 3))
-- dump round trip keeps the _ENV position
local r1 = load(string.dump(g1))
local r2 = load(string.dump(g2))
p("dump", uvnames(r1), uvnames(r2), uvnames(load(string.dump(g3))))
-- hot loop with a swapped environment: the JIT sees the same values
local function hot() local s = 0 for i = 1, 100 do s = s + K end return s end
debug.setupvalue(hot, 1, setmetatable({K = 3}, {__index = _G}))
p("hot", hot(), uvnames(hot))
