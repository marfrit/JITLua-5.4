--! modes: A,B
--! 5.4 error-path __close when the error passes a C function (a table.sort
--! comparator, a string.gsub replacement) before it reaches the frame that
--! closes the pending variables. PUC closes them there (luaD_pcall,
--! finishpcallk, lua_closethread), so a handler's caller is that frame's
--! caller: the C function that made the protected call from C (the main
--! chunk's lua_pcall in lua.c), nothing for a closed coroutine. This tree
--! ran the handlers of a protected call from C at the passed C function's
--! frame (the discarded Lua frames below were levels), and a coroutine that
--! died that way lost its pending variables: coroutine.close and the error
--! close of coroutine.wrap never called their handlers. Printed: the levels
--! each handler sees and its error object, the results. The chunk ends in
--! an error on purpose (protected call from C), which is why mode R is out.
local function closer (f) return setmetatable({}, {__close = f}) end
local function levels ()
  local t = {}
  for i = 2, 6 do
    local ar = debug.getinfo(i, "nSl")
    t[#t+1] = ar and (i .. "=" .. ar.what .. "/" .. tostring(ar.name) .. ":" ..
                      ar.currentline) or (i .. "=nil")
  end
  return table.concat(t, " ")
end

do  -- a coroutine that dies with an error through table.sort
  local co = coroutine.create(function ()
    local o <close> = closer(function (_, e) print("co outer", levels(), e) end)
    table.sort({1, 2, 3}, function (a, b)
      local x <close> = closer(function (_, e) print("co inner", levels(), e) end)
      error("E", 0)
    end)
  end)
  print("resume", coroutine.resume(co))
  print("status", coroutine.status(co))
  print("close", coroutine.close(co))
end

do  -- the same, the inner handler fails: the next one sees its error
  local co = coroutine.create(function ()
    local o <close> = closer(function (_, e) print("co2 outer", e) end)
    table.sort({1, 2, 3}, function (a, b)
      local x <close> = closer(function (_, e) print("co2 inner", e); error("X", 0) end)
      error("E", 0)
    end)
  end)
  print("resume", coroutine.resume(co))
  print("close", coroutine.close(co))
end

do  -- coroutine.wrap: the error closes the coroutine
  local f = coroutine.wrap(function ()
    string.gsub("a", "a", function ()
      local x <close> = closer(function (_, e) print("wrap handler", levels(), e) end)
      error("W", 0)
    end)
  end)
  print("wrap", pcall(f))
end

do  -- pcall from Lua with a C function between
  print("pcall", pcall(function ()
    table.sort({1, 2, 3}, function (a, b)
      local x <close> = closer(function (_, e) print("pcall handler", levels(), e) end)
      error("P", 0)
    end)
  end))
end

-- The main chunk's protected call from C catches this one; closers on both
-- sides of the C function.
local y <close> = closer(function (_, e) print("main outer", levels(), e) end)
local function g ()
  local z <close> = closer(function (_, e) print("main mid", levels(), e) end)
  table.sort({1, 2, 3}, function (a, b)
    local x <close> = closer(function (_, e) print("main inner", levels(), e) end)
    error("M", 0)
  end)
end
g()
