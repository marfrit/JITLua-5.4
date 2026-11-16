---! 5.4 debug hooks (derived from PUC-Lua 5.4.7 testes/db.lua): line events
---! (if/then, loops, large line gaps, no event for the sethook line, entry and
---! return rules), call/return/"tail call" events incl. C functions, fast
---! functions, pcall/xpcall, coroutine.wrap and debug.sethook itself,
---! getinfo(2) inside hooks ("hook '?'" frames, currentline, 't' istailcall,
---! 'r' transfer values via getlocal), nested hooks, return-hook locals,
---! count hooks, stripped chunks (line nil), per-coroutine hooks and the weak
---! _HOOKKEY registry table, hooks set inside a hot loop (JIT: traces are
---! flushed and the loop continues in the interpreter). Mode A compares with
---! PUC, mode B the JIT with the interpreter. Count hooks are not combined
---! with line hooks on purpose: PUC's count hook clobbers its oldpc and then
---! emits an extra line event, which this port does not replicate.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(label, table.concat(t, " "))
end
local function seq(t) return table.concat(t, ",") end

-- 1. line event sequences (PUC db.lua test() cases, verbatim)
local function test(s, l)
  collectgarbage()
  local got = {}
  local function f(event, line) got[#got+1] = line end
  debug.sethook(f, "l"); load(s)(); debug.sethook()
  p("line", seq(got), seq(got) == seq(l) and "ok" or ("expected " .. seq(l)))
end

test([[if
math.sin(1)
then
  a=1
else
  a=2
end
]], {2,3,4,7})


test([[
local function foo()
end
foo()
A = 1
A = 2
A = 3
]], {2, 3, 2, 4, 5, 6})
_G.A = nil


test([[--
if nil then
  a=1
else
  a=2
end
]], {2,5,6})

test([[a=1
repeat
  a=a+1
until a==3
]], {1,3,4,3,4})

test([[ do
  return
end
]], {2})

test([[local a
a=1
while a<=3 do
  a=a+1
end
]], {1,2,3,4,3,4,3,4,3,5})

test([[while math.sin(1) do
  if math.sin(1)
  then break
  end
end
a=1]], {1,2,3,6})

test([[for i=1,3 do
  a=i
end
]], {1,2,1,2,1,2,1,3})

test([[for i,v in pairs{'a','b'} do
  a=tostring(i) .. v
end
]], {1,2,1,2,1,3})

test([[for i=1,4 do a=1 end]], {1,1,1,1})

_G.a = nil


do   -- testing line info/trace with large gaps in source

  local a = {1, 2, 3, 10, 124, 125, 126, 127, 128, 129, 130,
             255, 256, 257, 500, 1000}
  local s = [[
     local b = {10}
     a = b[1] X + Y b[1]
     b = 4
  ]]
  for _, i in ipairs(a) do
    local subs = {X = string.rep("\n", i)}
    for _, j in ipairs(a) do
      subs.Y = string.rep("\n", j)
      local s = string.gsub(s, "[XY]", subs)
      test(s, {1, 2 + i, 2 + i + j, 2 + i, 2 + i + j, 3 + i + j})
    end
  end
end
_G.a = nil

-- 2. call/return/tail call events, C functions, fast functions, pcall, wrap
do
  local g, g1
  local function f(x) end
  function g(x) return f(x) end
  function g1(x) g(x) end
  local function h(x) local f = g1; return f(x) end
  local b = {}
  debug.sethook(function(e) b[#b+1] = e end, "cr")
  h(false)
  debug.sethook()
  p("events", seq(b))
  local n, ok = 0, true
  debug.sethook(function(e)
    local t = debug.getinfo(2, "t").istailcall
    if e == "tail call" then n = n + 1; ok = ok and t == true else ok = ok and t == false end
  end, "c")
  h(false)
  debug.sethook()
  p("tailcalls", n, ok)
  local ev = {}
  debug.sethook(function(e)
    local t = debug.getinfo(2, "nSr")
    ev[#ev+1] = e .. ":" .. tostring(t.name) .. ":" .. t.what .. ":" .. t.ntransfer
  end, "cr")
  local y = math.sin(3)
  local z = select("#", 10, 20, 30)
  local s = string.rep("a", 2)
  local q = pcall(function() return 1 end)
  local e1, e2 = pcall(error, "boom")
  local x1 = select("#", xpcall(function() return 1, 2 end, print))
  local co = coroutine.wrap(function() coroutine.yield(1) return 2 end)
  co(); co()
  local ok2, r2 = coroutine.resume(coroutine.create(function() return 7 end))
  debug.sethook()
  p("cevents", seq(ev))
end

-- 3. transfer values (db.lua "inspection of parameters/returned values")
do
  local on = false
  local inp, out
  local function hook(event)
    if not on then return end
    local ar = debug.getinfo(2, "ruS")
    local t = {}
    for i = ar.ftransfer, ar.ftransfer + ar.ntransfer - 1 do
      local _, v = debug.getlocal(2, i)
      t[#t + 1] = v
    end
    if event == "return" then out = t else inp = t end
  end
  debug.sethook(hook, "cr")
  on = true; math.sin(3); on = false
  p("transfer sin", seq(inp), seq(out))
  on = true; select(2, 10, 20, 30, 40); on = false
  p("transfer select", seq(inp), seq(out))
  local function foo(a, ...) return ... end
  local function foo1() on = not on; return foo(20, 10, 0) end
  foo1(); on = false
  p("transfer foo", seq(inp), seq(out))
  debug.sethook()
end

-- 4. hook frames: namewhat "hook", traceback wording, no event for the sethook line
do
  local count, nw, tb = 0, nil, nil
  local function f()
    nw = debug.getinfo(1).namewhat
    tb = string.match(debug.traceback(), "\n(.-)\n")
    count = count + 1
  end
  debug.sethook(f, "l")
  local a = 0
  _G.a = a
  a = 1
  debug.sethook()
  p("hookframe", count, nw, (tb:gsub("^.-:%d+: ", "")))
end

-- 5. nested hooks, getinfo(2, "l") inside a line hook, gethook mask/count
do
  local X, r = nil, {}
  local a = {}
  function a:f(a, b, ...) local arg = {...}; local c = 13 end
  debug.sethook(function(e)
    r[#r+1] = e
    r[#r+1] = select(2, pcall(load("a='joao'+1"))) and "err" or "noerr"
    debug.sethook(function(e, l)
      r[#r+1] = (debug.getinfo(2, "l").currentline == l) and "lineok" or "linebad"
      local f, m, c = debug.gethook()
      r[#r+1] = e .. m .. c
      debug.sethook(nil)
      X = {debug.getlocal(2, 1)}
    end, "l")
  end, "c")
  a:f(1, 2, 3, 4, 5)
  p("nested", seq(r), X[1], X[2] == a, debug.gethook())
end

-- 6. locals visible in a return hook (db.lua "bug in 5.2")
do
  local function collectlocals(level)
    local tab = {}
    for i = 1, math.huge do
      local n, v = debug.getlocal(level + 1, i)
      if not (n and string.find(n, "^[a-zA-Z0-9_]+$")) then break end
      tab[n] = v
    end
    return tab
  end
  local X
  local function foo(a, b, ...) do local x, y, z end local c, d = 10, 20 return end
  local function aux()
    if debug.getinfo(2).name == "foo" then
      local t, names = collectlocals(2), {}
      for n, v in pairs(t) do names[#names+1] = n .. "=" .. tostring(v) end
      table.sort(names)
      X = seq(names)
    end
  end
  debug.sethook(aux, "r"); foo(100, 200); debug.sethook()
  p("retlocals", X)
end

-- 7. count hooks
do
  local a = 0
  debug.sethook(function() a = a + 1 end, "", 1)
  a = 0; for i = 1, 1000 do end
  local a1 = a
  debug.sethook(function() a = a + 1 end, "", 4)
  a = 0; for i = 1, 1000 do end
  local a4 = a
  local f, m, c = debug.gethook()
  debug.sethook(function() a = a + 1 end, "", 4000)
  a = 0; for i = 1, 1000 do end
  local a4000 = a
  debug.sethook(print, "", 2^24 - 1)
  local c2 = ({debug.gethook()})[3]
  debug.sethook()
  p("count", 1000 < a1 and a1 < 1012, 250 < a4 and a4 < 255, m, c, a4000, c2 == 2^24 - 1, debug.gethook())
end

-- 8. local function visible to the debugger only after its definition; stripped chunk
do
  local co = load[[
  local A = function ()
    return x
  end
  return
]]
  local r = {}
  debug.sethook(function(e, l)
    if l == 3 or l == 4 then r[#r+1] = (debug.getlocal(2, 1)) end
  end, "l")
  co()
  debug.sethook()
  p("localinfo", seq(r))
  local function foo() local a = 1; local b = 2; return b end
  local s = load(string.dump(foo, true))
  local line, ev = true, nil
  debug.sethook(function(e, l) ev = e; line = l end, "l")
  local v = s(); debug.sethook(nil)
  p("stripped", v, ev, line)
end

-- 9. per-coroutine hooks and the registry hook table
do
  local co = coroutine.create(function(x)
    local a = 1
    coroutine.yield(debug.getinfo(1, "l"))
    coroutine.yield(debug.getinfo(1, "l").currentline)
    return a
  end)
  local tr = {}
  local foo = function(e, l) if l then tr[#tr+1] = l end end
  debug.sethook(co, foo, "lcr")
  local _, l = coroutine.resume(co, 10)
  p("cohook 1", #tr, tr[1] == l.currentline - 1, tr[2] == l.currentline, debug.gethook(co) == foo, debug.gethook())
  local ok, b, c = pcall(coroutine.resume, co)
  p("cohook 2", ok, b, c == l.currentline + 1)
  debug.setlocal(co, 1, 2, "hi")
  ok, b = coroutine.resume(co)
  p("cohook 3", ok, b, #tr, tr[4] == l.currentline + 2, debug.gethook(co) == foo, debug.gethook())
  local f, m, cnt = debug.gethook(co)
  p("cohook mask", m, cnt)
  local hk = debug.getregistry()._HOOKKEY
  p("hookkey", type(hk), getmetatable(hk).__mode)
  -- a hook set inside a coroutine that yields through a C boundary
  local function g(x) coroutine.yield(x) end
  local function f2(i)
    debug.sethook(function() end, "l")
    for j = 1, 100 do g(i + j) end
  end
  local w = coroutine.wrap(f2)
  w(10)
  p("cowrap", pcall(w))
  debug.sethook()
end

-- 10. hooks and hot loops (JIT: the loop is compiled, then a hook is set)
do
  local lines, calls, rets = {}, 0, 0
  local function f(x) return x + 1 end
  debug.sethook(function(ev, line)
    if ev == "line" then lines[#lines+1] = line
    elseif ev == "call" then calls = calls + 1
    elseif ev == "return" then rets = rets + 1 end
  end, "lcr")
  local s = 0
  for i = 1, 300 do s = s + f(i) end
  debug.sethook()
  p("hotloop", s, #lines, calls, rets, lines[1], lines[#lines])
  local n, m = 0, 0
  for i = 1, 500 do
    if i == 250 then debug.sethook(function(ev) n = n + 1 end, "l") end
    s = s + i
  end
  debug.sethook()
  for i = 1, 500 do
    if i == 100 then debug.sethook(function(ev) m = m + 1 end, "", 1) end
    s = s + i
  end
  debug.sethook()
  p("hotloop 2", s, n, m > 1000)
  -- a running trace hits a hook set by a called function
  local k = 0
  local function arm(i) if i == 200 then debug.sethook(function() k = k + 1 end, "c") end end
  for i = 1, 400 do arm(i) end
  debug.sethook()
  p("hotloop 3", k)
end
