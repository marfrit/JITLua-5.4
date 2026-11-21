--! modes: A,B
--! timeout: 120
--! 5.4 __close handlers on the error path of a pcall/xpcall called from Lua:
--! PUC closes the pending variables at the recover point, after the C stack
--! of the error is gone (ldo.c precover -> unroll -> finishpcallk ->
--! luaF_close with yy=1), so a handler there can yield, sees the pcall C
--! function as its caller (debug level 2), and an error in a handler is
--! caught by the same pcall and replaces the error object for the handlers
--! still to run. Printed: the yield sequence of the suite block
--! (locals.lua "yielding inside closing metamethods after an error"), the
--! levels a handler sees, error chains through yields, xpcall's message
--! handler, an error that passes through a C function, coroutine.close of a
--! coroutine suspended in such a handler, and the hook events. Fixed output
--! only.

local function closer (f)
  return setmetatable({}, {__close = f})
end
local function show (...)
  local t = table.pack(...)
  for i = 1, t.n do t[i] = tostring(t[i]) end
  return table.concat(t, " ")
end

-- 1. The suite block: x, y and z all yield, whether foo returns, a handler
-- raises an error, or foo itself raises.
do
  local out = {}
  local co = coroutine.wrap(function ()
    local function foo (err)
      local z <close> = closer(function (_, msg)
        out[#out+1] = "z:" .. tostring(msg)
        coroutine.yield("z")
        return 100, 200
      end)
      local y <close> = closer(function (_, msg)
        out[#out+1] = "y:" .. tostring(msg)
        coroutine.yield("y")
        if err then error(err + 20, 0) end
      end)
      local x <close> = closer(function (_, msg)
        out[#out+1] = "x:" .. tostring(msg)
        coroutine.yield("x")
        return 100, 200
      end)
      if err == 10 then error(err, 0) else return 10, 20 end
    end
    coroutine.yield(pcall(foo, nil))
    coroutine.yield(pcall(foo, 1))
    return pcall(foo, 10)
  end)
  local r = {}
  for i = 1, 15 do
    local ok, a, b, c = pcall(co)
    r[#r+1] = show(ok, a, b, c)
    if not ok then break end
  end
  print("1:", table.concat(r, " | "))
  print("1 handlers:", table.concat(out, " "))
end

-- 2. What a handler on the error path sees as its callers.
local function levels ()
  local t = {}
  for i = 2, 5 do  -- 2 = the handler that called levels()
    local ar = debug.getinfo(i, "nS")
    t[#t+1] = ar and (i .. "=" .. ar.what .. "/" .. tostring(ar.name)) or (i .. "=nil")
  end
  return table.concat(t, " ")
end
do
  local L
  local function foo ()
    local x <close> = closer(function (_, e) L = levels() end)
    error("E", 0)
  end
  print("2 pcall:", pcall(foo), L)
  print("2 xpcall:", xpcall(foo, function (m) return "h:" .. m end), L)
  local co = coroutine.create(function () return pcall(foo) end)
  print("2 co:", coroutine.resume(co))
  print("2 co levels:", L)
  -- An error with level 2 from a handler points at its caller (no position
  -- for the C function).
  local function bar ()
    local x <close> = closer(function () error("lvl2", 2) end)
    error("E", 0)
  end
  print("2 level 2:", pcall(bar))
  -- The traceback from inside such a handler.
  local tb
  local function baz ()
    local x <close> = closer(function () tb = debug.traceback("tb", 1) end)
    error("E", 0)
  end
  pcall(baz)
  tb = tb:gsub("\n[^\n]*%[C%]: in %?", ""):gsub("0x%x+", "ADDR")
  print("2 traceback:", tb)
end

-- 3. Error chains: each handler gets the error the previous one left.
do
  local seen = {}
  local function foo ()
    local a <close> = closer(function (_, e) seen[#seen+1] = "a:" .. tostring(e) end)
    local b <close> = closer(function (_, e) seen[#seen+1] = "b:" .. tostring(e); error("B", 0) end)
    local c <close> = closer(function (_, e) seen[#seen+1] = "c:" .. tostring(e) end)
    local d <close> = closer(function (_, e) seen[#seen+1] = "d:" .. tostring(e); error("D", 0) end)
    error("E", 0)
  end
  print("3:", pcall(foo))
  print("3 seen:", table.concat(seen, " "))
  seen = {}
  print("3 xpcall:", xpcall(foo, function (m) return "<" .. tostring(m) .. ">" end))
  print("3 xpcall seen:", table.concat(seen, " "))
  -- The same with a yield in every handler, inside a coroutine.
  seen = {}
  local function bar ()
    local a <close> = closer(function (_, e) seen[#seen+1] = "a:" .. tostring(e); coroutine.yield("a") end)
    local b <close> = closer(function (_, e) seen[#seen+1] = "b:" .. tostring(e); coroutine.yield("b"); error("B", 0) end)
    local c <close> = closer(function (_, e) seen[#seen+1] = "c:" .. tostring(e); coroutine.yield("c") end)
    error("E", 0)
  end
  local co = coroutine.wrap(function () return "done", pcall(bar) end)
  local r = {}
  for i = 1, 6 do
    local ok, a, b, c = pcall(co)
    r[#r+1] = show(ok, a, b, c)
    if not ok or a == "done" then break end
  end
  print("3 yields:", table.concat(r, " | "))
  print("3 yields seen:", table.concat(seen, " "))
end

-- 4. The error passes through a C function (a sort comparator) before the
-- pcall catches it: handlers inside and outside the comparator.
do
  local seen = {}
  local function foo ()
    local outer <close> = closer(function (_, e) seen[#seen+1] = "outer:" .. tostring(e) end)
    table.sort({3, 2, 1}, function (a, b)
      local inner <close> = closer(function (_, e) seen[#seen+1] = "inner:" .. tostring(e) end)
      error("cmp", 0)
    end)
  end
  print("4:", pcall(foo))
  print("4 seen:", table.concat(seen, " "))
  -- Inside a coroutine, with a yield in the outer handler (no C function
  -- left on the C stack by then).
  seen = {}
  local co = coroutine.wrap(function ()
    local function bar ()
      local outer <close> = closer(function (_, e)
        seen[#seen+1] = "outer:" .. tostring(e)
        coroutine.yield("outer")
      end)
      table.sort({3, 2, 1}, function (a, b) error("cmp", 0) end)
    end
    return "done", pcall(bar)
  end)
  print("4 co:", show(pcall(co)), show(pcall(co)))
  print("4 co seen:", table.concat(seen, " "))
end

-- 5. A coroutine suspended in an error-path handler, then closed.
do
  local seen = {}
  local co = coroutine.create(function ()
    local function foo ()
      local a <close> = closer(function (_, e) seen[#seen+1] = "a:" .. tostring(e) end)
      local b <close> = closer(function (_, e) seen[#seen+1] = "b:" .. tostring(e); coroutine.yield("b") end)
      error("E", 0)
    end
    return pcall(foo)
  end)
  print("5 resume:", coroutine.resume(co))
  print("5 close:", coroutine.close(co))
  print("5 seen:", table.concat(seen, " "), coroutine.status(co))
end

-- 6. A yield in an error-path handler that is not inside a coroutine resume
-- (a pcall inside a C callback) is still refused.
do
  local co = coroutine.wrap(function ()
    local r
    string.gsub("a", "a", function ()
      r = table.pack(pcall(function ()
        local x <close> = closer(function () coroutine.yield("no") end)
        error("E", 0)
      end))
    end)
    return show(table.unpack(r, 1, r.n))
  end)
  print("6:", pcall(co))
end

-- 7. Hook events around an error-path close.
do
  local ev = {}
  local function hook (e)
    local ar = debug.getinfo(2, "nS")
    ev[#ev+1] = e:sub(1, 1) .. ":" .. tostring(ar.name) .. "/" .. ar.what
  end
  local h = function () end
  local function foo ()
    local x <close> = closer(h)
    error("E", 0)
  end
  debug.sethook(hook, "cr")
  pcall(foo)
  debug.sethook()
  table.remove(ev, 1); table.remove(ev)
  print("7:", table.concat(ev, " "))
end

-- 8. Many pending handlers and collections in between: every handler runs
-- once, on its own value.
do
  local n, bad = 0, 0
  local function deep (k)
    local v <close> = closer(function (self, e)
      collectgarbage()
      n = n + 1
      if e ~= "E" then bad = bad + 1 end
    end)
    if k == 0 then error("E", 0) end
    return deep(k - 1)
  end
  print("8:", pcall(deep, 50), n, bad)
end
