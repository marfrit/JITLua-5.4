--! §4.3: every C -> Lua re-entry counts toward the C-call bound (PUC ldo.c
--! ccall / luaE_checkcstack, LUAI_MAXCCALLS). A C function that calls back
--! into Lua, which calls the C function again, ends in a recoverable
--! "C stack overflow" at PUC's depth instead of exhausting the native stack.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
-- Only the kind of error matters: positions and tracebacks differ by shape.
local function kind(e)
  e = tostring(e)
  if e:find("C stack overflow", 1, true) then return "C stack overflow" end
  if e:find("error in error handling", 1, true) then return "errerr" end
  if e:find("stack overflow", 1, true) then return "stack overflow" end
  return e
end
local count
local function run(name, f, ...)
  count = 0
  local ok, err = pcall(f, ...)
  p(name, ok, kind(err), count)
end

-- string.gsub with a function replacement (the PUC suite's cstack.lua shape)
do
  local function foo() count = count + 1; return string.gsub("a", ".", foo) end
  run("gsub-func", foo)
end

-- string.gsub with a table replacement, looked up through __index: two C
-- boundaries per cycle
do
  local t
  local function foo() count = count + 1; return string.gsub("a", ".", t) end
  t = setmetatable({}, {__index = foo})
  run("gsub-index", foo)
end

-- table.sort comparator
do
  local function foo() count = count + 1; table.sort({1, 2}, foo); return false end
  run("sort-comp", foo)
end

-- table.sort without a comparator: __lt from the C API
do
  local a, b, mt = {}, {}, {}
  mt.__lt = function() count = count + 1; table.sort({a, b}); return false end
  setmetatable(a, mt); setmetatable(b, mt)
  run("sort-lt", table.sort, {a, b})
end

-- __tostring from string.format (luaL_tolstring)
do
  local o
  o = setmetatable({}, {__tostring = function()
    count = count + 1; return string.format("%s", o) end})
  run("format-tostring", string.format, "%s", o)
end

-- __len from table.insert (luaL_len)
do
  local t
  t = setmetatable({}, {__len = function()
    count = count + 1; table.insert(t, 1); return 0 end})
  run("insert-len", table.insert, t, 1)
end

-- load with a reader function that loads again
do
  local first
  local function reader()
    count = count + 1
    local f, e = load(reader)
    if not f and not first then first = e end
    return nil
  end
  count = 0
  p("load-reader", type(load(reader)), kind(first), count)
end

-- pcall inside the cycle: both kinds of level count against the same bound,
-- and every level catches the error of the one below
do
  local function foo()
    count = count + 1
    return (pcall(string.gsub, "a", ".", foo))
  end
  count = 0
  p("pcall-gsub", foo(), count)
end

-- inside a coroutine: the resume itself takes one level
do
  local function foo() count = count + 1; return string.gsub("a", ".", foo) end
  count = 0
  local co = coroutine.create(foo)
  local ok, err = coroutine.resume(co)
  p("coroutine", ok, kind(err), count)
  count = 0
  ok, err = pcall(coroutine.wrap(foo))
  p("wrap", ok, kind(err), count)
end

-- to-be-closed variables of the unwound frames: every __close handler runs
-- after the overflow, at the level of the frame that catches it
do
  local closed = 0
  local mt = {__close = function() closed = closed + 1 end}
  local function foo()
    count = count + 1
    local x <close> = setmetatable({}, mt)
    local r = string.gsub("a", ".", foo)
    return r
  end
  run("close-unwind", foo)
  p("closed", closed)
  -- a __close handler that calls back through C, right below the bound
  closed = 0
  local mt2 = {__close = function()
    string.gsub("a", ".", function() closed = closed + 1 end) end}
  local function bar()
    count = count + 1
    local x <close> = setmetatable({}, mt2)
    local r = string.gsub("a", ".", bar)
    return r
  end
  run("close-reenter", bar)
  p("closed", closed)
end

-- finalizers: one runs a C level below the code the collector interrupted,
-- and a collection inside a finalizer ends (PUC ignores it, here it nests
-- up to the bound)
do
  local depth
  setmetatable({}, {__gc = function()
    local n = 0
    local function rec() n = n + 1; return string.gsub("a", ".", rec) end
    pcall(rec)
    depth = n
  end})
  collectgarbage(); collectgarbage()
  p("gc-depth", depth)
  local calls = 0
  local function mk()
    setmetatable({}, {__gc = function()
      calls = calls + 1; mk(); collectgarbage()
    end})
  end
  mk()
  for i = 1, 5 do collectgarbage() end
  p("gc-collect-in-gc", calls > 0)
end

-- message handlers: one runs for the overflow, and it may itself call back
-- through C (PUC leaves room above the bound for the handling)
do
  local function foo() count = count + 1; return string.gsub("a", ".", foo) end
  count = 0
  p("xpcall", xpcall(foo, function(m) return "H:" .. kind(m) end))
  p("xpcall-count", count)
  count = 0
  p("xpcall-reenter", xpcall(foo, function(m)
    return (string.gsub("x", ".", function() return "handled:" .. kind(m) end))
  end))
  -- a handler that overflows again
  count = 0
  p("xpcall-loop", (function()
    local ok, e = xpcall(foo, foo)
    return ok, kind(e)
  end)())
end

-- The count is exact on every path: the depth of a gsub recursion and of a
-- pcall recursion is unchanged after errors and normal returns through C.
local function depth_gsub()
  local n = 0
  local function rec() n = n + 1; return string.gsub("a", ".", rec) end
  pcall(rec)
  return n
end
local function depth_pcall()
  local n = 0
  local function rec() n = n + 1; pcall(rec) end
  pcall(rec)
  return n
end
p("depth", depth_gsub(), depth_pcall())
local g0, p0 = depth_gsub(), depth_pcall()
local function probe(name) p(name, depth_gsub() - g0, depth_pcall() - p0) end
for i = 1, 300 do string.gsub("a", ".", function() return "b" end) end
probe("after-return")
for i = 1, 300 do pcall(string.gsub, "a", ".", function() error("x") end) end
probe("after-error")
for i = 1, 300 do
  pcall(string.gsub, "a", ".", function()
    return string.gsub("a", ".", function() error("x") end)
  end)
end
probe("after-error-nested")
for i = 1, 300 do
  pcall(table.sort, {3, 2, 1}, function(a, b)
    pcall(string.gsub, "a", ".", function() error("y") end)
    error("x")
  end)
end
probe("after-error-sort")
for i = 1, 300 do
  xpcall(string.gsub, function(m) return m end, "a", ".", function() error("x") end)
end
probe("after-error-xpcall")
for i = 1, 5 do depth_gsub() end
probe("after-overflow")
for i = 1, 300 do
  local co = coroutine.wrap(function()
    string.gsub("a", ".", function() error("x") end)
  end)
  pcall(co)
end
probe("after-error-coroutine")
for i = 1, 300 do
  local co = coroutine.wrap(function()
    string.gsub("a", ".", function() coroutine.yield(1) end)
  end)
  pcall(co)
end
probe("after-yield-across-c")
for i = 1, 300 do
  local co = coroutine.wrap(function()
    pcall(string.gsub, "a", ".", function() error("x") end)
    coroutine.yield(1)
    pcall(string.gsub, "a", ".", function() error("x") end)
  end)
  co()
  string.gsub("a", ".", co)
end
probe("after-resume-from-c")
for i = 1, 300 do
  pcall(load, function() error("x") end)
end
probe("after-error-reader")
-- a Lua stack overflow with a pending to-be-closed value above the catcher:
-- closing needs stack itself
do
  local mt = {__close = function() end}
  local function deep() return 1 + deep() end
  local function f() local x <close> = setmetatable({}, mt); return deep() end
  p("close-stkov", kind(select(2, pcall(f))),
    kind(select(2, pcall(string.gsub, "a", ".", f))))
  probe("after-close-stkov")
end
p("fine", pcall(string.gsub, "abc", "%w", function(c) return c:upper() end))
