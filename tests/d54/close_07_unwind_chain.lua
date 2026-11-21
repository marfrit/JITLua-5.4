--! §2.3: the error path closes every pending <close> variable at or above the
--! level it stops at, each in a protected call, and an error inside a __close
--! replaces the error (5.4 luaF_close). lj_err.c:tbc_closeunwound passed the
--! level stack pointer through lj_state_checkstack: if the stack was resized,
--! the pointer belonged to the freed old stack, so savestack() in
--! lj_meta_tbccloseall produced a garbage offset and the "slot >= level" test
--! truncated the chain after the first handler (nondeterministic 5-8 of 10
--! runs; the offset is garbage because the stale pointer is compared, not
--! dereferenced, so ASan does not see it).
--! Each iteration runs in a fresh coroutine with a small initial stack and
--! recurses first, so the close setup has to grow the stack. The order must
--! be innermost first (z, y, x1, x) and the error must be the one raised by the
--! last handler (x: "@x").
--! This stress shape passed on the old tree as well (the moved-to address sat
--! lower there); the measured red shape is the same chain at file scope after
--! enough preceding code that the close setup grows the stack -- 5-8 of 10
--! runs truncated to one handler. The stale pointer was only compared and
--! never dereferenced, so a sanitizer cannot report it.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local function func2close(f)
  return setmetatable({}, {__close = f})
end

local function run()
  local seen = {}
  local function foo()
    local x <close> = func2close(function(_, msg)
      seen[#seen+1] = "x:" .. tostring(msg)
      assert(string.find(msg, "@y", 1, true))
      error("@x")
    end)
    local x1 <close> = func2close(function(_, msg)
      seen[#seen+1] = "x1:" .. tostring(msg)
      assert(string.find(msg, "@y", 1, true))
    end)
    local gc <close> = func2close(function() collectgarbage() end)
    local y <close> = func2close(function(_, msg)
      seen[#seen+1] = "y:" .. tostring(msg)
      assert(string.find(msg, "@z", 1, true))
      error("@y")
    end)
    local z <close> = func2close(function(_, msg)
      seen[#seen+1] = "z:" .. tostring(msg)
      assert(msg == nil)
      error("@z")
    end)
    return 200
  end
  local stat, msg = pcall(foo, false)
  assert(stat == false and string.find(msg, "@x", 1, true))
  assert(#seen == 4)
  return seen
end

-- Deep recursion first: the coroutine starts with LJ_STACK_START slots and
-- every level below fills them, so entering the erroring function and then
-- closing its pending slots both need more stack.
local function rec(n)
  if n == 0 then return run() end
  return rec(n - 1)
end

local ok, bad = 0, 0
for i = 1, 30 do
  local co = coroutine.create(function() return rec(60) end)
  local stat, seen = coroutine.resume(co)
  if stat and seen and #seen == 4 and seen[1]:find("z:", 1, true) and
     seen[2]:find("y:", 1, true) and seen[3]:find("x1:", 1, true) and
     seen[4]:find("x:", 1, true) then
    ok = ok + 1
  else
    bad = bad + 1
  end
end
p("chains", ok, bad)
