--! 5.4 arbitrary _ENV values (PUC parity): load()'s env argument may be any
--! value; PUC stores it as the chunk's _ENV upvalue, so _ENV resolves to it
--! and globals are _ENV.name (generic index path, with metamethods). A table
--! keeps the fast path; a non-table value errors with PUC's wording
--! "attempt to index a <type> value (upvalue '_ENV')". Also covers nested
--! functions and hot global loops (mode B: JIT on vs off) on a table and a
--! proxy env. Modes A/B/R (PUC-comparable).
local function norm(s) return (tostring(s):gsub("^.-:%d+: ", "")) end
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(label, table.concat(t, " "))
end
local function try(label, f)
  local r = table.pack(pcall(f))
  if r[1] then p(label, "ok", table.unpack(r, 2, r.n)) else p(label, "err", norm(r[2])) end
end

-- _ENV itself is the value, whatever its type.
local gfn = function() end
try("env number", function() return load("return _ENV", nil, nil, 123)() end)
try("env string", function() return load("return _ENV", nil, nil, "the env")() end)
try("env function", function() return load("return _ENV", nil, nil, gfn)() == gfn end)
try("env boolean", function() return load("return _ENV", nil, nil, true)() end)
try("env nil", function() return load("return _ENV", nil, nil, nil)() end)

-- A global access on a non-table env uses the generic index path.
try("num read", function() return load("return x", nil, nil, 123)() end)
try("num write", function() return load("x = 1", nil, nil, 123)() end)
try("str read", function() return load("return x", nil, nil, "abc")() end)
try("nil read", function() return load("return x", nil, nil, nil)() end)
try("nil write", function() return load("x = 1", nil, nil, nil)() end)
try("nil index", function() return load("return x.y", nil, nil, nil)() end)

-- Tables keep the fast path, including __index/__newindex proxies.
try("table read", function() return load("return x", nil, nil, {x = 7})() end)
try("table write", function()
  local t = {}
  local f = load("x = 5; return x", nil, nil, t)
  local r = f()
  return r, t.x
end)
try("proxy read", function()
  return load("return x", nil, nil,
    setmetatable({}, {__index = function(_, k) return "idx:" .. k end}))()
end)
try("proxy write", function()
  local t = setmetatable({}, {
    __index = function(tt, k) return rawget(tt, k) end,
    __newindex = function(tt, k, v) rawset(tt, k, v * 2) end})
  local f = load("w = 5; return w, x", nil, nil, t)
  local a, b = f()
  return a, b, t.w
end)

-- The number metatable applies to a number env (as in PUC).
do
  local old = debug.getmetatable(123)
  debug.setmetatable(123, {__index = function(_, k) return "num:" .. k end})
  try("num meta read", function() return load("return x", nil, nil, 123)() end)
  debug.setmetatable(123, old)
end

-- Nested functions capture the (non-table) env of their chunk.
try("nested num", function()
  local f = load("return function() return x end", nil, nil, 123)
  return f()()
end)
try("nested table", function()
  local f = load("return function() return x end", nil, nil, {x = 9})
  return f()()
end)

-- A chunk that does not touch _ENV loads fine with a non-table env.
p("load ok", (pcall(load, "return 1", nil, nil, 123)))

-- Hot global loops (mode B: JIT on vs off) on a table and a proxy env.
p("hot table", load("local s = 0 for i = 1, 1000 do s = s + K end return s",
  nil, nil, {K = 3})())
p("hot proxy", load("local s = 0 for i = 1, 1000 do s = s + K end return s",
  nil, nil, setmetatable({}, {__index = function() return 2 end}))())
