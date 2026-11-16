--! coroutine.close and <close> in coroutines: the relevant sections of the
--! PUC 5.4.7 test suite's coroutine.lua (lines 132-277 and 444-475 of the
--! vendored file), unchanged except for this header and the final print.
local debug = require'debug'
local function func2close (f)
  return setmetatable({}, {__close = f})
end

do
  -- ok to close a dead coroutine
  local co = coroutine.create(print)
  assert(coroutine.resume(co, "testing 'coroutine.close'"))
  assert(coroutine.status(co) == "dead")
  local st, msg = coroutine.close(co)
  assert(st and msg == nil)
  -- also ok to close it again
  st, msg = coroutine.close(co)
  assert(st and msg == nil)


  -- cannot close the running coroutine
  local st, msg = pcall(coroutine.close, coroutine.running())
  assert(not st and string.find(msg, "running"))

  local main = coroutine.running()

  -- cannot close a "normal" coroutine
  ;(coroutine.wrap(function ()
    local st, msg = pcall(coroutine.close, main)
    assert(not st and string.find(msg, "normal"))
  end))()

  -- cannot close a coroutine while closing it
  do
    local co
    co = coroutine.create(
      function()
        local x <close> = func2close(function()
            coroutine.close(co)   -- try to close it again
         end)
        coroutine.yield(20)
      end)
    local st, msg = coroutine.resume(co)
    assert(st and msg == 20)
    st, msg = coroutine.close(co)
    assert(not st and string.find(msg, "running coroutine"))
  end

  -- to-be-closed variables in coroutines
  local X

  -- closing a coroutine after an error
  local co = coroutine.create(error)
  local st, msg = coroutine.resume(co, 100)
  assert(not st and msg == 100)
  st, msg = coroutine.close(co)
  assert(not st and msg == 100)
  -- after closing, no more errors
  st, msg = coroutine.close(co)
  assert(st and msg == nil)

  co = coroutine.create(function ()
    local x <close> = func2close(function (self, err)
      assert(err == nil); X = false
    end)
    X = true
    coroutine.yield()
  end)
  coroutine.resume(co)
  assert(X)
  assert(coroutine.close(co))
  assert(not X and coroutine.status(co) == "dead")

  -- error closing a coroutine
  local x = 0
  co = coroutine.create(function()
    local y <close> = func2close(function (self,err)
      assert(err == 111)
      x = 200
      error(200)
    end)
    local x <close> = func2close(function (self, err)
      assert(err == nil); error(111)
    end)
    coroutine.yield()
  end)
  coroutine.resume(co)
  assert(x == 0)
  local st, msg = coroutine.close(co)
  assert(st == false and coroutine.status(co) == "dead" and msg == 200)
  assert(x == 200)
  -- after closing, no more errors
  st, msg = coroutine.close(co)
  assert(st and msg == nil)
end

do
  -- <close> versus pcall in coroutines
  local X = false
  local Y = false
  local function foo ()
    local x <close> = func2close(function (self, err)
      Y = debug.getinfo(2)
      X = err
    end)
    error(43)
  end
  local co = coroutine.create(function () return pcall(foo) end)
  local st1, st2, err = coroutine.resume(co)
  assert(st1 and not st2 and err == 43)
  assert(X == 43 and Y.what == "C")

  -- recovering from errors in __close metamethods
  local track = {}

  local function h (o)
    local hv <close> = o
    return 1
  end

  local function foo ()
    local x <close> = func2close(function(_,msg)
      track[#track + 1] = msg or false
      error(20)
    end)
    local y <close> = func2close(function(_,msg)
      track[#track + 1] = msg or false
      return 1000
    end)
    local z <close> = func2close(function(_,msg)
      track[#track + 1] = msg or false
      error(10)
    end)
    coroutine.yield(1)
    h(func2close(function(_,msg)
        track[#track + 1] = msg or false
        error(2)
      end))
  end

  local co = coroutine.create(pcall)

  local st, res = coroutine.resume(co, foo)    -- call 'foo' protected
  assert(st and res == 1)   -- yield 1
  local st, res1, res2 = coroutine.resume(co)   -- continue
  assert(coroutine.status(co) == "dead")
  assert(st and not res1 and res2 == 20)   -- last error (20)
  assert(track[1] == false and track[2] == 2 and track[3] == 10 and
         track[4] == 10)
end
-- (trigger C-code assertions)
do
  local A = coroutine.running()
  local B = coroutine.create(function() return coroutine.resume(A) end)
  local st, res = coroutine.resume(B)
  assert(st == true and res == false)

  local X = false
  A = coroutine.wrap(function()
    local _ <close> = func2close(function () X = true end)
    return pcall(A, 1)
  end)
  st, res = A()
  assert(not st and string.find(res, "non%-suspended") and X == true)
end


-- bug in 5.4.1
do
  -- coroutine ran close metamethods with invalid status during a
  -- reset.
  local co
  co = coroutine.wrap(function()
    local x <close> = func2close(function() return pcall(co) end)
    error(111)
  end)
  local st, errobj = pcall(co)
  assert(not st and errobj == 111)
  st, errobj = pcall(co)
  assert(not st and string.find(errobj, "dead coroutine"))
end

print("OK")
