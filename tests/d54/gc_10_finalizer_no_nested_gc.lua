--! §2.5.3 / lapi.c lua_gc: while a __gc metamethod runs (GCSTPGC), every
--! lua_gc option fails, so collectgarbage() and its other options called
--! from a finalizer answer fail (nil) and do not start a nested collection:
--! the other finalizers of the cycle run after the current one returns, in
--! PUC's order, also for the finalizers run when the state closes. A
--! finalizer that drops the last reference to another finalizable object
--! and calls collectgarbage() does not see that object finalized inside the
--! call. Printed: the order of the finalizer entries and exits and the
--! values the calls return.
local log = {}
local function mk (name, inner)
  return setmetatable({}, {__gc = function ()
    log[#log+1] = name .. "<"
    if inner then
      log[#log+1] = "collect=" .. tostring(collectgarbage())
      log[#log+1] = "step=" .. tostring(collectgarbage("step"))
      log[#log+1] = "stop=" .. tostring(collectgarbage("stop"))
      log[#log+1] = "restart=" .. tostring(collectgarbage("restart"))
      log[#log+1] = "isrunning=" .. tostring(collectgarbage("isrunning"))
      log[#log+1] = "count=" .. tostring(collectgarbage("count"))
    end
    log[#log+1] = ">" .. name
  end})
end
do
  local a = mk("a", true)
  local b = mk("b", false)
  local c = mk("c", true)
end
collectgarbage()
collectgarbage()
print(table.concat(log, " "))
print("running", collectgarbage("isrunning"))

log = {}
do
  local x = setmetatable({}, {__gc = function ()
    log[#log+1] = "x<"
    local y = setmetatable({}, {__gc = function () log[#log+1] = "y" end})
    y = nil
    log[#log+1] = tostring(collectgarbage())
    log[#log+1] = ">x"
  end})
end
collectgarbage(); collectgarbage(); collectgarbage()
print(table.concat(log, " "))

-- Finalizers that run when the state closes.
setmetatable({}, {__gc = function ()
  io.write("close ", tostring(collectgarbage()), " ", tostring(collectgarbage("count")), "\n")
end})
_G.keep = setmetatable({}, {__gc = function ()
  io.write("close keep ", tostring(collectgarbage("step")), "\n")
end})
print("end")
