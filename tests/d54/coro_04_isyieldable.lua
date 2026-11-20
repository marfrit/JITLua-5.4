--! §1.4 coroutine.isyieldable([co]): PUC's yieldable() is `(nCcalls & the
--! C-call flags) == 0`, so a coroutine between resumes (created, suspended,
--! dead) is yieldable; the main thread and a thread busy in a C call are not.
--! LuaJIT modelled only the resume frame and ignored the argument, so a
--! suspended or dead coroutine answered false.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local function y(co)
  if co then return coroutine.isyieldable(co) end
  return coroutine.isyieldable()
end

p("main", y())
local fresh = coroutine.create(function() coroutine.yield() end)
p("fresh", coroutine.status(fresh), y(fresh))
assert(coroutine.resume(fresh))
p("suspended", coroutine.status(fresh), y(fresh))
assert(coroutine.resume(fresh))
p("dead", coroutine.status(fresh), y(fresh))

-- from inside a coroutine: the running thread is yieldable, a normal (outer)
-- coroutine is, and the main thread stays unyieldable
local inner, outer
inner = coroutine.create(function()
  p("inner-self", coroutine.status(inner), y(inner))
  p("inner-outer", coroutine.status(outer), y(outer))
  coroutine.yield()
end)
outer = coroutine.create(function()
  p("outer-self", coroutine.status(outer), y(outer))
  coroutine.resume(inner)
  p("outer-again", coroutine.status(outer), y(outer))
  coroutine.yield()
end)
assert(coroutine.resume(outer))
p("main-again", y())

-- a bad argument is not silently ignored: PUC luaL_checkthread
local ok, msg = pcall(coroutine.isyieldable, nil)
p("badarg", ok, string.find(msg, "thread expected", 1, true) ~= nil)
