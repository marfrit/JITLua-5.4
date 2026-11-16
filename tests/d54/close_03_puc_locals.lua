--! 5.4 to-be-closed variables: the <close> sections of the PUC 5.4.7 test
--! suite's locals.lua (lines 206-571, 861-1046 and 1047-1057 of the vendored
--! file), unchanged except for this header and the final print. Sections
--! needing the PUC test library (T), hooks or a forced stack overflow are
--! left out.

print"testing to-be-closed variables"

local function stack(n) n = ((n == 0) or stack(n - 1)) end

local function func2close (f, x, y)
  local obj = setmetatable({}, {__close = f})
  if x then
    return x, obj, y
  else
    return obj
  end
end


do
  local a = {}
  do
    local b <close> = false   -- not to be closed
    local x <close> = setmetatable({"x"}, {__close = function (self)
                                                   a[#a + 1] = self[1] end})
    local w, y <close>, z = func2close(function (self, err)
                                assert(err == nil); a[#a + 1] = "y"
                              end, 10, 20)
    local c <close> = nil  -- not to be closed
    a[#a + 1] = "in"
    assert(w == 10 and z == 20)
  end
  a[#a + 1] = "out"
  assert(a[1] == "in" and a[2] == "y" and a[3] == "x" and a[4] == "out")
end

do
  local X = false

  local x, closescope = func2close(function (_, msg)
    stack(10);
    assert(msg == nil)
    X = true
  end, 100)
  assert(x == 100);  x = 101;   -- 'x' is not read-only

  -- closing functions do not corrupt returning values
  local function foo (x)
    local _ <close> = closescope
    return x, X, 23
  end

  local a, b, c = foo(1.5)
  assert(a == 1.5 and b == false and c == 23 and X == true)

  X = false
  foo = function (x)
    local _<close> = func2close(function (_, msg)
      -- without errors, enclosing function should be still active when
      -- __close is called
      assert(debug.getinfo(2).name == "foo")
      assert(msg == nil)
    end)
    local  _<close> = closescope
    local y = 15
    return y
  end

  assert(foo() == 15 and X == true)

  X = false
  foo = function ()
    local x <close> = closescope
    return x
  end

  assert(foo() == closescope and X == true)

end


-- testing to-be-closed x compile-time constants
-- (there were some bugs here in Lua 5.4-rc3, due to a confusion
-- between compile levels and stack levels of variables)
do
  local flag = false
  local x = setmetatable({},
    {__close = function() assert(flag == false); flag = true end})
  local y <const> = nil
  local z <const> = nil
  do
      local a <close> = x
  end
  assert(flag)   -- 'x' must be closed here
end

do
  -- similar problem, but with implicit close in for loops
  local flag = false
  local x = setmetatable({},
    {__close = function () assert(flag == false); flag = true end})
  -- return an empty iterator, nil, nil, and 'x' to be closed
  local function a ()
    return (function () return nil end), nil, nil, x
  end
  local v <const> = 1
  local w <const> = 1
  local x <const> = 1
  local y <const> = 1
  local z <const> = 1
  for k in a() do
      a = k
  end    -- ending the loop must close 'x'
  assert(flag)   -- 'x' must be closed here
end



do
  -- calls cannot be tail in the scope of to-be-closed variables
  local X, Y
  local function foo ()
    local _ <close> = func2close(function () Y = 10 end)
    assert(X == true and Y == nil)    -- 'X' not closed yet
    return 1,2,3
  end

  local function bar ()
    local _ <close> = func2close(function () X = false end)
    X = true
    do
      return foo()    -- not a tail call!
    end
  end

  local a, b, c, d = bar()
  assert(a == 1 and b == 2 and c == 3 and X == false and Y == 10 and d == nil)
end


do
  -- bug in 5.4.3: previous condition (calls cannot be tail in the
  -- scope of to-be-closed variables) must be valid for tbc variables
  -- created by 'for' loops.

  local closed = false

  local function foo ()
    return function () return true end, 0, 0,
           func2close(function () closed = true end)
  end

  local function tail() return closed end

  local function foo1 ()
    for k in foo() do return tail() end
  end

  assert(foo1() == false)
  assert(closed == true)
end


do
  -- bug in 5.4.4: 'break' may generate wrong 'close' instruction when
  -- leaving a loop block.

  local closed = false

  local o1 = setmetatable({}, {__close=function() closed = true end})

  local function test()
    for k, v in next, {}, nil, o1 do
      local function f() return k end   -- create an upvalue
      break
    end
    assert(closed)
  end

  test()
end


do print("testing errors in __close")

  -- original error is in __close
  local function foo ()

    local x <close> =
      func2close(function (self, msg)
        assert(string.find(msg, "@y"))
        error("@x")
      end)

    local x1 <close> =
      func2close(function (self, msg)
        assert(string.find(msg, "@y"))
      end)

    local gc <close> = func2close(function () collectgarbage() end)

    local y <close> =
      func2close(function (self, msg)
        assert(string.find(msg, "@z"))  -- error in 'z'
        error("@y")
      end)

    local z <close> =
      func2close(function (self, msg)
        assert(msg == nil)
        error("@z")
      end)

    return 200
  end

  local stat, msg = pcall(foo, false)
  assert(string.find(msg, "@x"))


  -- original error not in __close
  local function foo ()

    local x <close> =
      func2close(function (self, msg)
        -- after error, 'foo' was discarded, so caller now
        -- must be 'pcall'
        assert(debug.getinfo(2).name == "pcall")
        assert(string.find(msg, "@x1"))
      end)

    local x1 <close> =
      func2close(function (self, msg)
        assert(debug.getinfo(2).name == "pcall")
        assert(string.find(msg, "@y"))
        error("@x1")
      end)

    local gc <close> = func2close(function () collectgarbage() end)

    local y <close> =
      func2close(function (self, msg)
        assert(debug.getinfo(2).name == "pcall")
        assert(string.find(msg, "@z"))
        error("@y")
      end)

    local first = true
    local z <close> =
      func2close(function (self, msg)
        assert(debug.getinfo(2).name == "pcall")
        -- 'z' close is called once
        assert(first and msg == 4)
        first = false
        error("@z")
      end)

    error(4)    -- original error
  end

  local stat, msg = pcall(foo, true)
  assert(string.find(msg, "@x1"))

  -- error leaving a block
  local function foo (...)
    do
      local x1 <close> =
        func2close(function (self, msg)
          assert(string.find(msg, "@X"))
          error("@Y")
        end)

      local x123 <close> =
        func2close(function (_, msg)
          assert(msg == nil)
          error("@X")
        end)
    end
    os.exit(false)    -- should not run
  end

  local st, msg = xpcall(foo, debug.traceback)
  assert(string.match(msg, "^[^ ]* @Y"))

  -- error in toclose in vararg function
  local function foo (...)
    local x123 <close> = func2close(function () error("@x123") end)
  end

  local st, msg = xpcall(foo, debug.traceback)
  assert(string.match(msg, "^[^ ]* @x123"))
  assert(string.find(msg, "in metamethod 'close'"))
end


do   -- errors due to non-closable values
  local function foo ()
    local x <close> = {}
    os.exit(false)    -- should not run
  end
  local stat, msg = pcall(foo)
  assert(not stat and
    string.find(msg, "variable 'x' got a non%-closable value"))

  local function foo ()
    local xyz <close> = setmetatable({}, {__close = print})
    getmetatable(xyz).__close = nil   -- remove metamethod
  end
  local stat, msg = pcall(foo)
  assert(not stat and string.find(msg, "metamethod 'close'"))

  local function foo ()
    local a1 <close> = func2close(function (_, msg)
      assert(string.find(msg, "number value"))
      error(12)
    end)
    local a2 <close> = setmetatable({}, {__close = print})
    local a3 <close> = func2close(function (_, msg)
      assert(msg == nil)
      error(123)
    end)
    getmetatable(a2).__close = 4   -- invalidate metamethod
  end
  local stat, msg = pcall(foo)
  assert(not stat and msg == 12)
end


do   -- tbc inside close methods
  local track = {}
  local function foo ()
    local x <close> = func2close(function ()
      local xx <close> = func2close(function (_, msg)
        assert(msg == nil)
        track[#track + 1] = "xx"
      end)
      track[#track + 1] = "x"
    end)
    track[#track + 1] = "foo"
    return 20, 30, 40
  end
  local a, b, c, d = foo()
  assert(a == 20 and b == 30 and c == 40 and d == nil)
  assert(track[1] == "foo" and track[2] == "x" and track[3] == "xx")

  -- again, with errors
  local track = {}
  local function foo ()
    local x0 <close> = func2close(function (_, msg)
      assert(msg == 202)
        track[#track + 1] = "x0"
    end)
    local x <close> = func2close(function ()
      local xx <close> = func2close(function (_, msg)
        assert(msg == 101)
        track[#track + 1] = "xx"
        error(202)
      end)
      track[#track + 1] = "x"
      error(101)
    end)
    track[#track + 1] = "foo"
    return 20, 30, 40
  end
  local st, msg = pcall(foo)
  assert(not st and msg == 202)
  assert(track[1] == "foo" and track[2] == "x" and track[3] == "xx" and
         track[4] == "x0")
end


do
  -- yielding inside closing metamethods while returning
  -- (bug in 5.4.3)

  local extrares    -- result from extra yield (if any)

  local function check (body, extra, ...)
    local t = table.pack(...)   -- expected returns
    local co = coroutine.wrap(body)
    if extra then
      extrares = co()    -- runs until first (extra) yield
    end
    local res = table.pack(co())   -- runs until yield inside '__close'
    assert(res.n == 2 and res[2] == nil)
    local res2 = table.pack(co())   -- runs until end of function
    assert(res2.n == t.n)
    for i = 1, #t do
      if t[i] == "x" then
        assert(res2[i] == res[1])    -- value that was closed
      else
        assert(res2[i] == t[i])
      end
    end
  end

  local function foo ()
    local x <close> = func2close(coroutine.yield)
    local extra <close> = func2close(function (self)
      assert(self == extrares)
      coroutine.yield(100)
    end)
    extrares = extra
    return table.unpack{10, x, 30}
  end
  check(foo, true, 10, "x", 30)
  assert(extrares == 100)

  local function foo ()
    local x <close> = func2close(coroutine.yield)
    return
  end
  check(foo, false)

  local function foo ()
    local x <close> = func2close(coroutine.yield)
    local y, z = 20, 30
    return x
  end
  check(foo, false, "x")

  local function foo ()
    local x <close> = func2close(coroutine.yield)
    local extra <close> = func2close(coroutine.yield)
    return table.unpack({}, 1, 100)   -- 100 nils
  end
  check(foo, true, table.unpack({}, 1, 100))

end

do
  -- yielding inside closing metamethods after an error

  local co = coroutine.wrap(function ()

    local function foo (err)

      local z <close> = func2close(function(_, msg)
        assert(msg == nil or msg == err + 20)
        coroutine.yield("z")
        return 100, 200
      end)

      local y <close> = func2close(function(_, msg)
        -- still gets the original error (if any)
        assert(msg == err or (msg == nil and err == 1))
        coroutine.yield("y")
        if err then error(err + 20) end   -- creates or changes the error
      end)

      local x <close> = func2close(function(_, msg)
        assert(msg == err or (msg == nil and err == 1))
        coroutine.yield("x")
        return 100, 200
      end)

      if err == 10 then error(err) else return 10, 20 end
    end

    coroutine.yield(pcall(foo, nil))  -- no error
    coroutine.yield(pcall(foo, 1))    -- error in __close
    return pcall(foo, 10)     -- 'foo' will raise an error
  end)

  local a, b = co()   -- first foo: no error
  assert(a == "x" and b == nil)    -- yields inside 'x'; Ok
  a, b = co()
  assert(a == "y" and b == nil)    -- yields inside 'y'; Ok
  a, b = co()
  assert(a == "z" and b == nil)    -- yields inside 'z'; Ok
  local a, b, c = co()
  assert(a and b == 10 and c == 20)   -- returns from 'pcall(foo, nil)'

  local a, b = co()   -- second foo: error in __close
  assert(a == "x" and b == nil)    -- yields inside 'x'; Ok
  a, b = co()
  assert(a == "y" and b == nil)    -- yields inside 'y'; Ok
  a, b = co()
  assert(a == "z" and b == nil)    -- yields inside 'z'; Ok
  local st, msg = co()             -- reports the error in 'y'
  assert(not st and msg == 21)

  local a, b = co()    -- third foo: error in function body
  assert(a == "x" and b == nil)    -- yields inside 'x'; Ok
  a, b = co()
  assert(a == "y" and b == nil)    -- yields inside 'y'; Ok
  a, b = co()
  assert(a == "z" and b == nil)    -- yields inside 'z'; Ok
  local st, msg = co()    -- gets final error
  assert(not st and msg == 10 + 20)

end


do
  -- an error in a wrapped coroutine closes variables
  local x = false
  local y = false
  local co = coroutine.wrap(function ()
    local xv <close> = func2close(function () x = true end)
    do
      local yv <close> = func2close(function () y = true end)
      coroutine.yield(100)   -- yield doesn't close variable
    end
    coroutine.yield(200)   -- yield doesn't close variable
    error(23)              -- error does
  end)

  local b = co()
  assert(b == 100 and not x and not y)
  b = co()
  assert(b == 200 and not x and y)
  local a, b = pcall(co)
  assert(not a and b == 23 and x and y)
end


do

  -- error in a wrapped coroutine raising errors when closing a variable
  local x = 0
  local co = coroutine.wrap(function ()
    local xx <close> = func2close(function (_, msg)
      x = x + 1;
      assert(string.find(msg, "@XXX"))
      error("@YYY")
    end)
    local xv <close> = func2close(function () x = x + 1; error("@XXX") end)
    coroutine.yield(100)
    error(200)
  end)
  assert(co() == 100); assert(x == 0)
  local st, msg = pcall(co); assert(x == 2)
  assert(not st and string.find(msg, "@YYY"))   -- should get error raised

  local x = 0
  local y = 0
  co = coroutine.wrap(function ()
    local xx <close> = func2close(function (_, err)
      y = y + 1;
      assert(string.find(err, "XXX"))
      error("YYY")
    end)
    local xv <close> = func2close(function ()
      x = x + 1; error("XXX")
    end)
    coroutine.yield(100)
    return 200
  end)
  assert(co() == 100); assert(x == 0)
  local st, msg = pcall(co)
  assert(x == 1 and y == 1)
  -- should get first error raised
  assert(not st and string.find(msg, "%w+%.%w+:%d+: YYY"))

end


-- a suspended coroutine should not close its variables when collected
local co
co = coroutine.wrap(function()
  -- should not run
  local x <close> = func2close(function () os.exit(false) end)
  co = nil
  coroutine.yield()
end)
co()                 -- start coroutine
print("OK")
