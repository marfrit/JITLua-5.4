--! §4.9 debug information that PUC's db.lua checks after its tail-call
--! section: names of metamethod frames (without the "__" prefix, the bit
--! operators included), the generic 'for' iterator, a finalizer; tracebacks
--! with a nil message and with skipped levels; upvalue counts of the closures
--! a library function builds per call; the 'end' line in activelines; names
--! and positions in code without debug info; a coroutine that ends in an
--! error while a return hook is set.
local function show(what, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(what .. ": " .. table.concat(t, " | "))
end

-- 1. Metamethod frames.
do
  local a = {}
  local function f() local ar = debug.getinfo(1, "n"); return ar.namewhat .. " " .. tostring(ar.name) end
  local mt = {}
  for _, ev in ipairs{"index", "add", "sub", "mul", "div", "mod", "pow", "unm", "idiv", "len",
                      "concat", "band", "bor", "bxor", "shl", "shr", "bnot"} do
    mt["__" .. ev] = f
  end
  setmetatable(a, mt)
  show("index/arith", a[3], a + 3, 3 - a, a * 3, a / 3, 3 % a, a ^ 3, -a, a // 3, #a, a .. a)
  show("constants", a + 30000, a - 3.0, a * 3.0, 1 .. a, a .. "x", a.x, a["y"])
  show("bit", a & 3, a | 3, 3 ~ a, a << 3, 3 >> a, ~a)
  local r
  local function g() local ar = debug.getinfo(1, "n"); r = ar.namewhat .. " " .. tostring(ar.name); return true end
  local c = setmetatable({}, {__eq = g, __lt = g, __le = g, __newindex = g, __call = g, __close = g})
  local d = setmetatable({}, getmetatable(c))
  local t = {}
  local _ = c == d; t[#t + 1] = r
  _ = c < d; t[#t + 1] = r
  _ = c <= d; t[#t + 1] = r
  _ = c > d; t[#t + 1] = r
  _ = c >= d; t[#t + 1] = r
  c.x = 1; t[#t + 1] = r
  c(1); t[#t + 1] = r
  do local x <close> = c end
  t[#t + 1] = r
  show("compare/newindex/call/close", table.unpack(t))
  -- The name in a traceback and in an argument error.
  local tb = setmetatable({}, {__index = function() return (debug.traceback("tb", 1)) end})
  show("traceback names the event", (tb.x:match("in metamethod '[^']*'")))
  local e = setmetatable({}, {__index = string.rep, __add = string.rep})
  show("argument error", pcall(function() return e.x end))
  show("argument error 2", pcall(function() return e + 1 end))
end

-- 2. The generic 'for' iterator and a finalizer.
do
  local r
  local function it() local ar = debug.getinfo(1, "n"); r = ar.namewhat .. " / " .. tostring(ar.name) end
  for _ in it do end
  show("for iterator", r)
  show("for iterator error", pcall(function() for _ in string.rep do end end))
  local name
  local function fin() local ar = debug.getinfo(1, "nS"); name = ar.namewhat .. " " .. tostring(ar.name) .. " " .. ar.what end
  local function make() setmetatable({}, {__gc = fin}) end
  make()
  collectgarbage(); collectgarbage()
  show("finalizer", name)
  -- A function called by the finalizer is an ordinary call.
  local inner
  local function callee() local ar = debug.getinfo(1, "n"); inner = ar.namewhat .. " " .. tostring(ar.name) end
  local function make2() setmetatable({}, {__gc = function() callee() end}) end
  make2()
  collectgarbage(); collectgarbage()
  show("function called by a finalizer", inner)
end

-- 3. Tracebacks.
do
  show("non-string message", debug.traceback(print) == print, debug.traceback(print, 4) == print)
  show("nil message", type(debug.traceback(nil)), (debug.traceback(nil, 1):match("^[^\n]*")))
  local co = coroutine.create(function() coroutine.yield() end)
  coroutine.resume(co)
  show("coroutine, nil message, level", (debug.traceback(co, nil, 0):gsub("\n.*", "")),
       select(2, debug.traceback(co, nil, 0):gsub("\n", "")), select(2, debug.traceback(co, nil, 1):gsub("\n", "")),
       select(2, debug.traceback(co, nil, 40):gsub("\n", "")))
  local function deep(lvl, n)
    if lvl == 0 then return (debug.traceback("message", n)) end
    return (deep(lvl - 1, n))
  end
  local function sizes(total, start)
    local s = deep(total, start)
    local lines = select(2, s:gsub("\n", ""))
    return lines .. (s:match("\n\t(%.%.%.[^\n]*)") or "")
  end
  local t = {}
  for _, c in ipairs{{1, 1}, {10, 1}, {19, 1}, {20, 1}, {21, 1}, {22, 1}, {30, 1}, {30, 9}, {30, 10}, {51, 1}, {51, 30}, {51, 51}} do
    t[#t + 1] = c[1] .. "," .. c[2] .. "=" .. coroutine.wrap(sizes)(c[1], c[2])
  end
  show("sizes", table.concat(t, " ; "))
end

-- 4. Upvalue counts, active lines.
do
  show("nups", debug.getinfo(print, "u").nups, debug.getinfo(math.sin, "u").nups,
       debug.getinfo(string.gmatch("abc", "a"), "u").nups > 0,
       debug.getinfo(coroutine.wrap(print), "u").nups > 0)
  local function lines(f)
    local t = {}
    for l in pairs(debug.getinfo(f, "L").activelines) do t[#t + 1] = l - debug.getinfo(f, "S").linedefined end
    table.sort(t)
    return table.concat(t, ",")
  end
  local f1 = function(x)
    local a = 1
    return a
  end
  local f2 = function(x)
    local a = 1
    if x then
      a = 2
    end
  end
  local f3 = function() return 1 end
  show("activelines", lines(f1), lines(f2), lines(f3))
end

-- 5. Code without debug info.
do
  local function strip(f) return load(string.dump(f, true)) end
  local up = 12
  local f = strip(function() local x; return up end)
  show("upvalue name", debug.getupvalue(f, 1), debug.setupvalue(f, 1, 13))
  local g = strip(function() return debug.getinfo(1, "l").currentline, debug.getinfo(1, "S").short_src end)
  show("current line", g())
  local function rt(u) local v = u; return function(x) return x.y.z, v() end end
  local s = strip(rt)
  show("index field", pcall(s(nil), {}))
  show("call upvalue", pcall(s(nil), {y = {}}))
  show("index nil", pcall(s(print), nil))
  show("arith", pcall(strip(function() local t = {}; return t + 1 end)))
  show("argument", pcall(strip(function() return string.rep() end)))
  show("error level 1", pcall(strip(function() error("lvl1") end)))
  show("error level 2", pcall(strip(function() error("lvl2", 2) end)))
  local tb = strip(function() return (debug.traceback("tb", 1)) end)()
  -- The private dump format drops linedefined when stripping (PUC keeps it).
  show("traceback", (tb:match("\n\t([^\n]*)"):gsub("<%?:%d+>", "<?:N>")))
  local hl = {}
  local h = strip(function() local a = 1; local b = 2; return b end)
  debug.sethook(function(e, l) hl[#hl + 1] = e .. ":" .. tostring(l) end, "l")
  h(); debug.sethook()
  show("line hook", hl[1])
end

-- 6. A coroutine that ends in an error while a return hook is set.
do
  local n = 0
  local co = coroutine.create(function() error("in coroutine") end)
  debug.sethook(function() n = n + 1 end, "r")
  local ok, msg = coroutine.resume(co)
  debug.sethook()
  show("resume error under a return hook", ok, (tostring(msg):gsub("^.-:%d+: ", "")), n > 0)
  local w = coroutine.wrap(function() error("in wrap") end)
  debug.sethook(function() n = n + 1 end, "r")
  local ok2, msg2 = pcall(w)
  debug.sethook()
  show("wrap error under a return hook", ok2, (tostring(msg2):gsub("^.-:%d+: ", "")))
end
