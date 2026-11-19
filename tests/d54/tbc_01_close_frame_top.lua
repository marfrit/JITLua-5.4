--! 5.4 <close> and the stack top of the __close call frame. The VM builds
--! the call frame above any open results of a preceding call with open
--! results (return f() in a <close> scope) using MULTRES, a scratch register.
--! MULTRES is only live directly after such a call; at any other UCLO it must
--! not be added to the frame top. On x64 the stale value placed the frame
--! beyond maxstack in a plain block exit and the interpreter crashed
--! (SIGSEGV, x64 only); the other paths cover the discarded call, open
--! results, a multi-result return, a nested multret call, break/goto, error
--! unwinding and coroutine.close.
local function pr(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local log
local function mk(tag)
  return setmetatable({}, {__close = function(o, e)
    log[#log+1] = tag .. ":" .. tostring(e)
  end})
end
local function take()
  local s = table.concat(log, ","); log = {}; return s
end

-- The original crash: a plain block exit closes, then the caller pcalls.
local function crash()
  local t = {}
  do
    local t2 <close> = setmetatable({}, {__close = function() t.closed = true end})
    t2.what = "ever"
  end
  return t.closed
end
pr("plain-block", pcall(crash))

-- A discarded call statement right before the block exit (predecessor CALL,
-- results discarded: B=1, so its MULTRES must not be used).
log = {}
local function discarded()
  do
    local x <close> = mk("x")
    local function f(a, b) return a, b end
    f(1, 2)
  end
  return "done"
end
pr("discarded", discarded(), take())

-- return f(...) with open results in a <close> scope: here MULTRES is live
-- and the __close frame must sit above the open result slots.
log = {}
local function openres()
  local x <close> = mk("x")
  return (function(a, b) return a, b end)(10, 20)
end
pr("openres", openres())
pr("openres-log", take())

-- nested multret call (CALLM with open results) plus a <close>:
-- return f(g()) must return all results of f.
log = {}
local function nested()
  local x <close> = mk("x")
  local function g() return 1, 2, 3 end
  -- g() last in the argument list: its results are expanded (CALLM, open)
  local function f(a, b, c, d) return a + b + c + d, b, c end
  return f(9, g())
end
pr("nested", nested())
pr("nested-log", take())

-- break out of a loop inside a <close> scope, then pcall around it.
log = {}
local function brk()
  local acc = 0
  do
    local x <close> = mk("x")
    for i = 1, 100 do
      if i == 3 then break end
      acc = acc + i
    end
  end
  return acc
end
pr("break", pcall(brk))
pr("break-log", take())

-- goto out of a block with a <close>.
log = {}
local function jump()
  do
    local x <close> = mk("x")
    goto done
  end
  ::done::
  return "jumped"
end
pr("goto", pcall(jump), take())

-- error unwinding through two <close> levels.
log = {}
local function boom()
  local a <close> = mk("a")
  local b <close> = mk("b")
  error("kaboom", 0)
end
local ok, err = pcall(boom)
pr("error", ok, err, take())

-- a suspended coroutine with a pending <close>, closed via coroutine.close.
log = {}
local co = coroutine.create(function()
  local x <close> = mk("co")
  coroutine.yield("y")
end)
pr("co-resume", coroutine.resume(co))
pr("co-close", coroutine.close(co))
pr("co-log", take())

-- the __close call itself sees the right locals: the closed value is the
-- object, the error argument is nil on a normal exit.
local seen
log = {}
local function args()
  do
    local x <close> = setmetatable({tag = "v"}, {__close = function(o, e)
      seen = tostring(o.tag) .. "/" .. tostring(e)
    end})
  end
  return seen
end
pr("args", args())
