--! §4.2 tail calls into C functions, the shapes the first test left out:
--! - a fast function that hands over to a metamethod (tostring -> __tostring,
--!   pairs -> __pairs) is not a tail call of the bytecode: the metamethod takes
--!   the frame of the fast function, whether it is a C or a Lua function;
--! - a trace that starts in the function making the tail call and leaves it
--!   through a Lua metamethod;
--! - __call resolving to a C function in tail position (one more argument);
--! - a vararg function making the tail call: its locals stay visible to the
--!   debug API, as in PUC 5.4, where the caller frame is kept.
--! Every line must be the same with the JIT on and off, and the same as PUC.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

-- 1. C metamethod behind a fast function, in and out of tail position.
local file = io.stdout
local n = 0
for _ = 1, 3000 do n = n + (#tostring(file) > 0 and 1 or 0) end
p("tostring C mm", n)
local function ts(x) return tostring(x) end
n = 0
for _ = 1, 3000 do n = n + (#ts(file) > 0 and 1 or 0) end
p("tail tostring C mm", n)
local cp = setmetatable({10, 20}, {__pairs = ipairs})
n = 0
for _ = 1, 3000 do for _, v in pairs(cp) do n = n + v end end
p("pairs C mm", n)
local function tp(x) return pairs(x) end
n = 0
for _ = 1, 3000 do for _, v in tp(cp) do n = n + v end end
p("tail pairs C mm", n)

-- 2. Traces that start in the function making the tail call. The driver is
-- not compiled, so the callee gets its own root trace.
local function drive(f, cnt, want)
  local c = 0
  for i = 1, cnt do if f(i) == want then c = c + 1 end end
  return c
end
if rawget(_G, "jit") then jit.off(drive) end
local obj = setmetatable({}, {__tostring = function() local z = 1; return "L" end})
local function g2() local pad1, pad2 = 7, 8; return tostring(obj) end
p("root: tostring -> Lua mm", drive(g2, 500, "L"))
local r = ("x"):rep(500):gsub(".", g2)
p("root from gsub", r == ("L"):rep(500), #r)
local pobj = setmetatable({}, {__pairs = function() return next, {a = 1}, nil end})
local function g4() local q = "q"; return pairs(pobj) end
p("root: pairs -> Lua mm", drive(g4, 500, next))
local function g3(i) local a, b = "a", "b"; return pcall(tostring, i) end
p("root: tail pcall", drive(g3, 500, true))
local function g6(...) return select("#", ...) end
p("root: vararg tail select", drive(g6, 500, 1))
local function g7(...) local a = ...; return tostring(obj) end
p("root: vararg tostring -> Lua mm", drive(g7, 500, "L"))

-- 3. __call resolving to a C function in tail position. The call before it
-- leaves stale temporaries above the arguments.
local cobj = setmetatable({x = 5, y = 6}, {__call = rawget})
local function cf(k) local a = math.max(1, 2, 3, 4, 5, 6); return cobj(k) end
n = 0
for _ = 1, 20000 do n = n + cf("x") + cf("y") end
p("tail __call rawget", n)
local un = setmetatable({10, 20, 30}, {__call = table.unpack})
local function cu(i, j) local pad = math.min(5, 4, 3, 2, 1); return un(i, j) end
n = 0
for _ = 1, 20000 do local a, b = cu(1, 2); n = n + a + b + cu(3, 3) end
p("tail __call unpack", n)
local req = setmetatable({}, {__call = rawequal})
local function cq(v) local pad = math.min(5, 4, 3, 2, 1); return req(v) end
n = 0
for _ = 1, 20000 do if cq(req) then n = n + 1 end if cq(1) then n = n + 100 end end
p("tail __call rawequal", n)

-- 4. Vararg functions: tail calls to C in hot loops, and the caller's locals.
local function vsel(...) return select("#", ...) end
local function vres(c, ...) return coroutine.resume(c, ...) end
local co = coroutine.create(function(a) while true do a = coroutine.yield(a + 1) end end)
n = 0
for i = 1, 20000 do local _, v = vres(co, i); n = n + v + vsel(i, i, i) end
p("vararg hot", n)
local function v1(...) local a, b = 11, 22; return debug.getlocal(1, 1) end
p("vararg getlocal", v1())
p("vararg getlocal", v1(7, 8, 9))
local function v2(q, ...) local a, b = 11, 22; return debug.getlocal(1, 3) end
p("vararg fixed getlocal", v2(5, 6))
local function v3(...) return debug.getlocal(1, -2) end
p("vararg getlocal -2", v3("x", "y"))
local function v4(...) local a = 1; return debug.setlocal(1, 1, "set") end
p("vararg setlocal", v4(1, 2))
local function v5(...) return debug.traceback("m", 1) end
p("vararg traceback", (select(2, v5(1, 2):gsub("\n", "\n"))) >= 2)
local function v6(...) local t = {...}; return error("ve" .. #t, 1) end
p("vararg error", select(2, pcall(v6, 1, 2)))

-- 5. Side exits and errors inside a tail-called pcall/xpcall: the trace is
-- left with the caller, the continuation, the pcall frame and the callee on
-- the stack, and the pcall nesting count has to come out even.
local function depth()
  local d = 0
  local function rec() d = d + 1; return pcall(rec) end
  rec()
  return d
end
local d1 = depth()
local function inner(i)
  if i % 1000 == 999 then error("boom" .. i, 0) end
  if i % 7 == 3 then return "s" end
  return i
end
local function step(i) return pcall(inner, i) end
local function hnd(m) return "H:" .. m end
local function xstep(i) return xpcall(inner, hnd, i) end
local errs, strs, sum, last = 0, 0, 0, nil
for i = 1, 40000 do
  local ok, v = step(i)
  if not ok then errs = errs + 1 elseif v == "s" then strs = strs + 1 else sum = sum + v end
  ok, v = xstep(i)
  if not ok then errs = errs + 1; last = v elseif v == "s" then strs = strs + 1 else sum = sum + v end
end
p("side exits in tail pcall", errs, strs, sum, last)
for i = 1, 300 do g3(i) end
p("depth stable", d1 == depth())
