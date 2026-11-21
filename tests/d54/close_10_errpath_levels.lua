--! modes: A,B
--! 5.4 debug levels inside a __close handler that is not run by a pcall
--! from Lua: coroutine.close of a coroutine that died with an error or is
--! suspended, the error close of coroutine.wrap, and the main chunk's
--! protected call from C (lua.c docall -> lua_pcall). PUC resets the
--! CallInfo chain before it closes (lua_closethread, luaD_pcall), so the
--! frames being closed are not levels: the handler's caller is the C function
--! that made the protected call, or nothing for a closed coroutine. Printed:
--! the levels a handler sees in each case. The chunk ends in an error on
--! purpose (the last case), which is also why mode R is out: the reload
--! wrapper adds frames below the main chunk. Fixed output only.
local function closer (f) return setmetatable({}, {__close = f}) end
local function levels ()
  local t = {}
  for i = 2, 5 do  -- 2 = the handler that called levels()
    local ar = debug.getinfo(i, "nS")
    t[#t+1] = ar and (i .. "=" .. ar.what .. "/" .. tostring(ar.name)) or (i .. "=nil")
  end
  return table.concat(t, " ")
end

do  -- coroutine.close of a coroutine that died with pending closers
  local L, Y
  local co = coroutine.create(function ()
    local x <close> = closer(function (_, e) L = levels(); Y = e end)
    error("E", 0)
  end)
  print("close dead:", coroutine.resume(co))
  print("close dead:", coroutine.close(co), L, Y)
end

do  -- the same with two closers, the second one failing
  local L = {}
  local co = coroutine.create(function ()
    local a <close> = closer(function (_, e) L[#L+1] = "a " .. levels() .. " " .. tostring(e) end)
    local b <close> = closer(function (_, e) L[#L+1] = "b " .. levels(); error("B", 0) end)
    error("E", 0)
  end)
  coroutine.resume(co)
  print("close dead 2:", coroutine.close(co))
  print("close dead 2:", table.concat(L, " | "))
end

do  -- coroutine.wrap: an error closes the coroutine
  local L
  local f = coroutine.wrap(function ()
    local x <close> = closer(function (_, e) L = levels() end)
    error("E", 0)
  end)
  print("wrap:", pcall(f))
  print("wrap:", L)
end

do  -- coroutine.close of a suspended coroutine
  local L
  local co = coroutine.create(function ()
    local x <close> = closer(function (_, e) L = levels() end)
    coroutine.yield()
  end)
  coroutine.resume(co)
  print("close suspended:", coroutine.close(co), L)
end

-- The main chunk's protected call from C catches this one.
local x <close> = closer(function (_, e) print("main:", levels(), e) end)
error("Emain", 0)
