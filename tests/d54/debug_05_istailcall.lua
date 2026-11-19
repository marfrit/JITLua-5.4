--! §4.9 debug.getinfo(level, "t").istailcall without a hook. PUC 5.4 keeps a
--! flag in the CallInfo of every Lua function entered by OP_TAILCALL; a C
--! function reached by a tail call is an ordinary call. Covered here:
--! - tail call, plain call, tail recursion at depths 0, 1, 2 and 100;
--! - vararg functions, __call, a metamethod behind a fast function;
--! - tail calls into C functions that call back into Lua;
--! - coroutines: resumed by a tail call, tail calls across a yield, a
--!   suspended coroutine inspected from outside;
--! - errors: traceback text, the frames an error handler sees, the frames
--!   that survive a caught error;
--! - a hook installed and removed in the middle of a chain of tail calls;
--! - the same shapes in hot loops, so compiled code has to rebuild the frames
--!   with their marks at trace exits (run at -O0..-O3 by the harness).
--! Every line must be the same with the JIT on and off, and the same as PUC.

-- One entry per level from the caller of stack() down to the main chunk (or
-- the base of the coroutine): kind of function, then T for a tail call. The
-- main chunk has no flag here: how it was called is up to the host program.
local function stack(co)
  local t = {}
  local lvl = co and 0 or 2
  while true do
    local ar
    if co then ar = debug.getinfo(co, lvl, "St") else ar = debug.getinfo(lvl, "St") end
    if not ar then break end
    if ar.what == "main" then t[#t + 1] = "m"; break end
    t[#t + 1] = ar.what:sub(1, 1) .. (ar.istailcall and "T" or "-")
    lvl = lvl + 1
  end
  return table.concat(t, " ")
end

local function show(what, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(what .. ": " .. table.concat(t, " | "))
end

-- 1. Plain call, tail call, chains of tail calls.
local function leaf() return (stack()) end
local function t1() return leaf() end
local function t2() return t1() end
local function mid() local s = leaf(); return s end
local function top() return mid() end
local function top2() local s = top(); return s end
show("plain", leaf())
show("tail 1", t1())
show("tail 2", t2())
show("plain under tail", top())
show("plain under tail under plain", top2())
show("main chunk", stack())

-- 2. Tail recursion and plain recursion.
local function rec(n)
  if n == 0 then return (stack()) end
  return rec(n - 1)
end
local function nrec(n)
  if n == 0 then return (stack()) end
  local s = nrec(n - 1)
  return s
end
local function alt(n)
  if n == 0 then return (stack()) end
  if n % 2 == 0 then return alt(n - 1) end
  local s = alt(n - 1)
  return s
end
for _, n in ipairs{0, 1, 2, 100} do show("tail recursion " .. n, rec(n)) end
for _, n in ipairs{0, 1, 2} do show("plain recursion " .. n, nrec(n)) end
show("plain recursion 100", (nrec(100):gsub("L%- ", "")), select(2, nrec(100):gsub("L%-", "")))
for _, n in ipairs{1, 2, 3, 6} do show("alternating " .. n, alt(n)) end

-- 3. Vararg functions, __call, a Lua metamethod behind a fast function.
local function va(...) return (stack()) end
local function tva(...) return va(...) end
local function vat(...) return leaf() end
local function vav(...) return tva(...) end
show("vararg callee", va(1, 2), tva(1, 2), tva())
show("vararg caller", vat(1, 2, 3), vav(1, 2, 3))
local callable = setmetatable({}, {__call = function(self, ...) return (stack()) end})
local function tcall(...) return callable(...) end
local function pcallable(...) local s = callable(...); return s end
show("__call", callable(1), tcall(1), pcallable(1))
local named = setmetatable({}, {__tostring = function()
  return tostring(debug.getinfo(1, "t").istailcall)
end})
local function tts(x) return tostring(x) end
show("__tostring", tostring(named), tts(named))
local obj = {}
function obj:get() return (stack()) end
function obj:wrap() return self:get() end
show("method", obj:get(), obj:wrap())

-- 4. Tail calls into C functions that call back.
local function inner() return leaf() end
local function outer() return pcall(inner) end
local function outer2() return outer() end
local function sel() return select(2, pcall(leaf)) end
local function sub() return (string.gsub("x", "x", leaf)) end
local function tsub() return string.gsub("x", "x", inner) end
local function xp() return xpcall(inner, print) end
show("pcall", outer())
show("pcall under tail", outer2())
show("select+pcall", sel())
show("gsub", sub(), tsub())
show("xpcall", xp())
local function cinfo()
  -- The C function itself, reached by a tail call: sort calls the comparator.
  local r
  local function cmp(a, b)
    r = r or (debug.getinfo(2, "St").what .. ":" .. tostring(debug.getinfo(2, "t").istailcall))
    return a < b
  end
  local function srt(t) return table.sort(t, cmp) end
  srt{3, 1, 2}
  return r
end
show("C function after a tail call", cinfo())

-- 5. Coroutines.
local function yrec(n)
  if n == 0 then
    local a = stack()
    coroutine.yield(a)
    return (stack())
  end
  return yrec(n - 1)
end
local co = coroutine.wrap(function() return yrec(3) end)
local function resume_tail() return co() end
show("coroutine, wrap in tail position", resume_tail())
show("coroutine, after the yield", resume_tail())
local co2 = coroutine.create(function(...)
  local a = stack()
  coroutine.yield(a)
  return yrec(2)
end)
local function resume2() return coroutine.resume(co2) end
show("coroutine body", resume2())
show("coroutine tail calls", resume2())
show("suspended coroutine from outside", stack(co2))
show("coroutine end", resume2())
local co3 = coroutine.create(function() local s = leaf(); coroutine.yield(s); return (t1()) end)
show("coroutine plain/tail", select(2, coroutine.resume(co3)), stack(co3),
     select(2, coroutine.resume(co3)))

-- 6. Errors.
local function boom() error("boom") end
local function b1() return boom() end
local function b2() local r = b1(); return r end
local function b3() return b2() end
local function tb(f)
  local ok, msg = xpcall(f, debug.traceback)
  -- Stop at the main chunk: what is below it belongs to the host program.
  local t = {}
  for line in tostring(msg):gmatch("[^\n]+") do
    if line:find("tail calls", 1, true) then t[#t + 1] = "(tail)"
    elseif line:find("%[C%]") then t[#t + 1] = "[C]"
    else
      local ln = line:match(":(%d+): in ")
      if ln then t[#t + 1] = "L" end
    end
    if line:find("in main chunk", 1, true) then break end
  end
  return table.concat(t, " ")
end
show("traceback shape", tb(b3))
show("traceback text has the tail-call line",
     select(2, xpcall(b3, debug.traceback)):find("(...tail calls...)", 1, true) ~= nil)
show("handler view", select(2, xpcall(b3, function() return (stack()) end)))
local function tbtext(f)
  local src = debug.getinfo(1, "S").short_src
  local _, msg = xpcall(f, debug.traceback)
  local t = {}
  for line in tostring(msg):gmatch("[^\n]+") do
    if line:find(src, 1, true) then
      t[#t + 1] = "FILE" .. line:sub(select(2, line:find(src, 1, true)) + 1)
    elseif line:find("tail calls", 1, true) then
      t[#t + 1] = (line:gsub("^%s+", ""))
    end
    if line:find("in main chunk", 1, true) then break end
  end
  return table.concat(t, " ; ")
end
show("traceback text", tbtext(b3))
-- A function entered by a tail call has no name: the call site below it
-- belongs to the function it replaced.
local function nm()
  local ar = debug.getinfo(1, "n")
  return tostring(ar.name) .. "/" .. ar.namewhat
end
local function tnm() return nm() end
local function pnm() local s = tnm(); return s end
show("name", nm(), tnm(), pnm())
local function keeper()
  local ok = pcall(b3)
  return ok, (stack())
end
local function k2() return keeper() end
show("after a caught error", k2())
local function thrower() error(setmetatable({}, {__tostring = function() return "E" end})) end
local function k3()
  local ok, e = pcall(function() return thrower() end)
  return (stack())
end
local function k4() return k3() end
show("after a caught error object", k4())

-- 7. A hook installed in the middle of a chain of tail calls.
local function deep()
  local s1 = stack()
  debug.sethook(function() end, "cr")
  local s2 = stack()
  local s3 = leaf()
  local s4 = t1()
  debug.sethook()
  local s5 = stack()
  local s6 = t1()
  return s1 .. " / " .. s2 .. " / " .. s3 .. " / " .. s4 .. " / " .. s5 .. " / " .. s6
end
local function via() return deep() end
local function via2() return via() end
show("hook mid-chain", via2())
do
  local ev = {}
  local function g(x) if x then return 1 end return 2 end
  local function h(x) return g(x) end
  local function k(x) local r = h(x); return r end
  local function hook(e)
    ev[#ev + 1] = e:sub(1, 1) .. (debug.getinfo(2, "t").istailcall and "T" or "-")
  end
  local function run() debug.sethook(hook, "cr"); k(true); debug.sethook() end
  local function trun() return run() end
  trun()
  show("hook events", table.concat(ev, " "))
end

-- 8. Hot loops: the frames are rebuilt at trace exits.
local N = 400
local function tally(t, s) t[s] = (t[s] or 0) + 1 end
local function report(what, t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for i = 1, #keys do keys[i] = keys[i] .. " x" .. t[keys[i]] end
  show(what, table.concat(keys, " ; "))
end

do  -- Tail recursion compiled as a loop, left at the base case.
  local t = {}
  for i = 1, N do tally(t, rec(i % 5 == 0 and 0 or 100)) end
  report("hot tail recursion", t)
  t = {}
  for i = 1, N do tally(t, rec(i % 3)) end
  report("hot tail recursion 0..2", t)
  t = {}
  for i = 1, 60 do tally(t, (nrec(40):gsub(" ", ""))) end
  report("hot plain recursion", t)
  t = {}
  for i = 1, N do tally(t, alt(i % 7)) end
  report("hot alternating", t)
end

do  -- Inlined tail call with a rare exit inside the callee.
  local function rare(i) if i % 97 == 0 then return (stack()) end return i end
  local function w(i) return rare(i) end
  local function p(i) local r = rare(i); return r end
  local function ww(i) return w(i) end
  local function pw(i) local r = w(i); return r end
  local function wp(i) return p(i) end
  local t = {}
  for i = 1, N do
    local a = w(i); if a ~= i then tally(t, "w " .. a) end
    local b = p(i); if b ~= i then tally(t, "p " .. b) end
    local c = ww(i); if c ~= i then tally(t, "ww " .. c) end
    local d = pw(i); if d ~= i then tally(t, "pw " .. d) end
    local e = wp(i); if e ~= i then tally(t, "wp " .. e) end
    local f = rare(i); if f ~= i then tally(t, "direct " .. f) end
  end
  report("hot inlined", t)
end

do  -- A side trace that starts inside a tail-called function.
  local function side(i)
    if i % 3 == 0 then
      if i % 51 == 0 then return (stack()) end
      return -i
    end
    return i
  end
  local function w(i) return side(i) end
  local function p(i) local r = w(i); return r end
  local t = {}
  for i = 1, N do
    local a = w(i); if type(a) == "string" then tally(t, "w " .. a) end
    local b = p(i); if type(b) == "string" then tally(t, "p " .. b) end
  end
  report("hot side trace", t)
end

do  -- Varargs, __call and methods in tail position.
  local function rare(i, ...) if i % 89 == 0 then return (stack()) end return i end
  local function v(...) return rare(...) end
  local function vv(...) return v(...) end
  local function fv(i, ...) local r = v(i, ...); return r end
  local cobj = setmetatable({}, {__call = function(self, i) return rare(i) end})
  local function tc(i) return cobj(i) end
  local m = {}
  function m:get(i) if i % 83 == 0 then return (stack()) end return i end
  function m:wrap(i) return self:get(i) end
  local t = {}
  for i = 1, N do
    local a = v(i, 1, 2); if a ~= i then tally(t, "v " .. a) end
    local b = vv(i, 1); if b ~= i then tally(t, "vv " .. b) end
    local c = fv(i); if c ~= i then tally(t, "fv " .. c) end
    local d = tc(i); if d ~= i then tally(t, "__call " .. d) end
    local e = m:wrap(i); if e ~= i then tally(t, "method " .. e) end
  end
  report("hot vararg/__call/method", t)
end

do  -- Tail calls into C from compiled code, with Lua frames above the C frame.
  local function rare(i) if i % 79 == 0 then return (stack()) end return i end
  local function w(i) return rare(i) end
  local function pc(i) return pcall(w, i) end
  local function pc2(i) return select(2, pcall(rare, i)) end
  local t = {}
  for i = 1, N do
    local ok, a = pc(i); if a ~= i then tally(t, "pcall " .. a) end
    local b = pc2(i); if b ~= i then tally(t, "select " .. b) end
  end
  report("hot tail call into C", t)
end

do  -- A trace that starts in a tail-called function and returns below it.
  local function low(i)
    local x = 0
    for j = 1, 3 do x = x + j end
    if i % 71 == 0 then return (stack()) end
    return x
  end
  local function w(i) return low(i) end
  local function caller(i)
    local r = w(i)
    if i % 73 == 0 then return (stack()) end
    return r
  end
  local function tcaller(i) return caller(i) end
  local t = {}
  for i = 1, N do
    local a = caller(i); if a ~= 6 then tally(t, "caller " .. a) end
    local b = tcaller(i); if b ~= 6 then tally(t, "tcaller " .. b) end
  end
  report("hot return to lower frame", t)
end

do  -- The same stack slot: first a tail-called frame, then a plain one.
  local function rare(i, k) if i % k == 0 then return (stack()) end return i end
  local function w(i, k) return rare(i, k) end
  local t = {}
  for i = 1, N do
    local a = w(i, 67); if a ~= i then tally(t, "tail " .. a) end
    a = rare(i, 61); if a ~= i then tally(t, "plain " .. a) end
    a = w(i, 59); if a ~= i then tally(t, "tail again " .. a) end
  end
  report("hot slot reuse", t)
end

do  -- Tail calls inside a coroutine driven from a hot loop.
  local function gen(n)
    local function step(i)
      if i > n then return (stack()) end
      coroutine.yield(i % 53 == 0 and stack() or i)
      return step(i + 1)
    end
    return coroutine.wrap(function() return step(1) end)
  end
  local g = gen(N)
  local t = {}
  for i = 1, N + 1 do
    local a = g(); if a ~= i then tally(t, a) end
  end
  report("hot coroutine", t)
end

do  -- Garbage collection while marked frames are live.
  local function g(n)
    if n == 0 then
      collectgarbage(); collectgarbage()
      return (stack())
    end
    local junk = {n}
    return g(n - 1)
  end
  local function fresh() return (function(n) return g(n) end)(20) end
  local t = {}
  for i = 1, 20 do tally(t, fresh()) end
  report("gc with marked frames", t)
end
