--! 5.4 debug hooks at the coroutine yield/resume boundary (PUC coroutine.lua
--! 337-354, "testing single trace of coroutines"). The C call of
--! coroutine.yield is finished when the coroutine is resumed, so its return
--! event lands there, with the values passed to resume as the transfer values.
--! Printed: the event sequence of several yield shapes (mask "clr" and "r"
--! only), the levels and transfer values seen from inside the return hook, the
--! order of the events of the coroutine against those of the resuming thread,
--! coroutine.wrap, and what a hook that fails or yields at that event does.
--! Fixed output only; no timing, no addresses.

-- Collect the event names of a coroutine run, mask given.
local function trace(mask, body, nargs, ...)
  local co = coroutine.create(body)
  local t = {}
  debug.sethook(co, function (e) t[#t+1] = e end, mask)
  local ok, n = true, 0
  while ok and n < 6 do
    local a = { ... }
    ok = select(1, coroutine.resume(co, table.unpack(a, 1, nargs)))
    n = n + 1
  end
  debug.sethook()
  return table.concat(t, ","), n, coroutine.status(co)
end

-- 1. The suite shape: yield(10) on one line, return 20 on the next.
print("1:", trace("clr", function () coroutine.yield(10) return 20 end, 0))
-- 2. The same with the return mask alone: PUC fires the event without a call
-- event, so this must not depend on the call mask.
print("2:", trace("r", function () coroutine.yield(10) return 20 end, 0))
-- 3. No yield: the coroutine ends in the first resume.
print("3:", trace("clr", function () return 20 end, 0))
-- 4. Yield in the middle of an expression, after a Lua call.
print("4:", trace("clr", function ()
  local function g () return 1 end
  return g() + coroutine.yield(1)
end, 0))
-- 5. Yield inside a called Lua function.
print("5:", trace("clr", function ()
  local function g () coroutine.yield(1) return 2 end
  return g()
end, 0))
-- 6. Yield with no value, resumed with two values.
print("6:", trace("clr", function () coroutine.yield() return 1 end, 2, 7, 8))
-- 7. Two yields.
print("7:", trace("clr", function () coroutine.yield(1) coroutine.yield(2) return 3 end, 0))
-- 8. Yield through a pcall of the coroutine itself.
print("8:", trace("clr", function ()
  local ok = pcall(coroutine.yield, 1)
  return ok
end, 0))
-- 9. The yield is not yieldable inside a C callback of the coroutine.
print("9:", select(2, pcall(trace, "clr", function ()
  local function f () coroutine.yield(1) return "x" end
  return string.gsub("ab", ".", f)
end, 0)))

-- 10. Levels and transfer values inside the return hook of the yield: the
-- transfer values are the ones passed to resume, read with debug.getlocal.
do
  local out = {}
  local co = coroutine.create(function ()
    local a, b, c = coroutine.yield(10)
    return a, b, c
  end)
  debug.sethook(co, function (e)
    if e ~= "return" then return end
    local t = {}
    for i = 2, 4 do
      local ar = debug.getinfo(i, "nS")
      t[#t+1] = ar and (i .. ":" .. ar.what .. "/" .. tostring(ar.name))
                or (i .. ":nil")
    end
    local ar2 = debug.getinfo(2, "r")
    local tv = {}
    for k = ar2.ftransfer, ar2.ftransfer + ar2.ntransfer - 1 do
      local nm, v = debug.getlocal(2, k)
      tv[#tv+1] = tostring(nm ~= nil) .. "=" .. tostring(v)
    end
    out[#out+1] = "ret " .. table.concat(t, " ") .. " ftr=" ..
      tostring(ar2.ftransfer) .. " ntr=" .. tostring(ar2.ntransfer) ..
      " vals[" .. table.concat(tv, " ") .. "]"
  end, "clr")
  print("10 r1:", coroutine.resume(co))
  print("10 r2:", coroutine.resume(co, "a", "b"))
  print("10 status:", coroutine.status(co))
  debug.sethook(co)
  for i = 1, #out do print("10." .. i, out[i]) end
end

-- 11. Hooks on both threads into one list: where does the coroutine's return
-- event of the yield sit against the events of the resuming thread?
do
  local ev = {}
  local function mhook (e)
    local ar = debug.getinfo(2, "nS")
    ev[#ev+1] = "m." .. e .. "." .. tostring(ar and ar.name)
  end
  local function chook (e)
    local ar = debug.getinfo(2, "nS")
    ev[#ev+1] = "c." .. e .. "." .. tostring(ar and ar.name)
  end
  local co = coroutine.create(function ()
    coroutine.yield(10)
    return 20
  end)
  debug.sethook(mhook, "clr")
  debug.sethook(co, chook, "clr")
  local n = 0
  repeat n = n + 1 until not coroutine.resume(co) or n > 4
  debug.sethook()
  debug.sethook(co)
  print("11:", table.concat(ev, " "))
end

-- 12. The same shape through coroutine.wrap (the hook is set inside).
do
  local tr = {}
  local f = coroutine.wrap(function ()
    debug.sethook(function (e) tr[#tr+1] = e end, "clr")
    coroutine.yield(10)
    return 20
  end)
  local n = 0
  repeat
    local ok, v = pcall(f)
    n = n + 1
    if not ok then tr[#tr+1] = "err" break end
  until v == nil or n > 4
  debug.sethook()
  print("12:", table.concat(tr, ","), n)
end

-- 13. A hook that fails at the return event of the yield.
do
  local co = coroutine.create(function () coroutine.yield(1) return 2 end)
  debug.sethook(co, function (e) if e == "return" then error("boom") end end, "r")
  print("13 a:", pcall(coroutine.resume, co))
  print("13 b:", pcall(coroutine.resume, co))
  print("13 status:", coroutine.status(co))
  debug.sethook()
end

-- 14. The hook itself yields (PUC allows a hook to yield, without values).
do
  local co = coroutine.create(function () return 1 end)
  local tr = {}
  debug.sethook(co, function (e)
    tr[#tr+1] = e
    if e == "return" then coroutine.yield() end
  end, "r")
  print("14 a:", pcall(coroutine.resume, co))
  print("14 b:", pcall(coroutine.resume, co))
  print("14 status:", coroutine.status(co))
  debug.sethook()
  print("14 trace:", table.concat(tr, ","))
end

-- 15. coroutine.isyieldable() inside the return event of a yield.
do
  local co = coroutine.create(function () coroutine.yield(1) return 2 end)
  local y = {}
  debug.sethook(co, function (e)
    if e == "return" then y[#y+1] = tostring(coroutine.isyieldable()) end
  end, "r")
  print("15 a:", pcall(coroutine.resume, co))
  print("15 b:", pcall(coroutine.resume, co))
  debug.sethook()
  print("15:", table.concat(y, " "), coroutine.status(co))
end
