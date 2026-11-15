-- coroutine.close / coroutine.running, Lua 5.4 semantics (PUC 5.4.7 reference).
local t, ismain = coroutine.running()
print("running", type(t), ismain)

local co = coroutine.create(function() coroutine.yield(1) end)
print("resume1", coroutine.resume(co))
print("close1", coroutine.close(co), coroutine.status(co))
print("close1b", coroutine.close(co))  -- dead coroutine closes again: true

local co2 = coroutine.create(function() error("boom", 0) end)
print("resume2", coroutine.resume(co2))
local ok, msg = coroutine.close(co2)
print("close2", ok, msg)
print("status2", coroutine.status(co2))

local co3 = coroutine.create(function() return 7 end)
print("resume3", coroutine.resume(co3))
print("close3", coroutine.close(co3), coroutine.status(co3))

print("close-running", pcall(coroutine.close, coroutine.running()))

local co4 = coroutine.create(function()
  local inner, ii = coroutine.running()
  print("inner-running", type(inner) == "thread", ii)
  coroutine.yield()
end)
print("resume4", coroutine.resume(co4))
print("close4", coroutine.close(co4))
