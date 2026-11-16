--! 5.4 to-be-closed variables: error paths, coroutine.close, goto/break,
--! returns (no tail call inside a <close> scope), const-ness and the
--! declaration errors. The interpreter is the oracle (mode A vs PUC); traces
--! abort on BC_TBC/UCLO, so mode B is the same path.
local log = {}
local function mk(tag)
  return setmetatable({}, {__close = function(o, e)
    log[#log+1] = tag .. ":" .. tostring(e)
  end})
end
local function flush(label) print(label, table.concat(log, ",")); log = {} end
local function strip(msg) return (tostring(msg):gsub("^[^:]*:%d+: ", "")) end

-- An error inside the block: __close receives the error object, in reverse
-- order, before pcall returns it.
local ok, err = pcall(function()
  local a <close> = mk("a")
  local b <close> = mk("b")
  error("boom", 0)
end)
flush("error")
print("pcall", ok, err)

-- An error raised by a __close replaces the error object; later closes see it.
ok, err = pcall(function()
  local a <close> = mk("a")
  local b <close> = setmetatable({}, {__close = function() error("in close", 0) end})
  local c <close> = mk("c")
  error("first", 0)
end)
flush("close-error")
print("pcall", ok, err)

-- Nested pcall boundaries: only the frames being unwound close.
ok, err = pcall(function()
  local outer <close> = mk("outer")
  local ok2, err2 = pcall(function()
    local inner <close> = mk("inner")
    error("inner-err", 0)
  end)
  log[#log+1] = "after-inner:" .. tostring(ok2) .. ":" .. tostring(err2)
  return "done"
end)
flush("nested")
print("pcall", ok, err)

-- goto out of nested blocks closes innermost first; the loop body closes per
-- iteration; break closes before leaving.
do
  local a <close> = mk("g1")
  for i = 1, 3 do
    local b <close> = mk("loop" .. i)
    if i == 2 then goto out end
  end
  ::out::
  log[#log+1] = "at-out"
end
flush("goto")

-- Return from inside a <close> scope is not a tail call: the callee runs
-- before the variable closes.
local function callee() log[#log+1] = "callee"; return 1, 2 end
local function f()
  local a <close> = mk("f")
  return callee()
end
print("return", f())
flush("return-order")

-- Multiple returns and a return of the closed value itself.
local function g()
  local a <close> = mk("g")
  return a, "x"
end
local r1, r2 = g()
print("return2", type(r1), r2)
flush("return2")

-- coroutine.close on a suspended coroutine closes its pending variables with
-- nil; on a coroutine that died with an error, with the error object.
local co = coroutine.create(function()
  local a <close> = mk("co1")
  local b <close> = mk("co2")
  coroutine.yield(1)
  log[#log+1] = "not reached"
end)
print("resume", coroutine.resume(co))
print("close", coroutine.close(co), coroutine.status(co))
flush("co-suspended")
co = coroutine.create(function()
  local a <close> = mk("dead")
  error("co-err", 0)
end)
print("resume", coroutine.resume(co))
flush("co-after-resume")
print("close", coroutine.close(co), coroutine.status(co))
flush("co-dead")
co = coroutine.wrap(function()
  local a <close> = setmetatable({}, {__close = function() error("close-err", 0) end})
  coroutine.yield(1)
end)
print("wrap", co())

-- nil and false are allowed and ignored; other values need __close.
do
  local n <close> = nil
  local f <close> = false
  log[#log+1] = "nil-false-ok"
end
flush("nilfalse")
print("non-closable", strip(select(2, pcall(load("local x <close> = 42")))))
print("multi", strip(select(2, load("local a <close>, b <close> = 1, 2"))))
print("assign", strip(select(2, load("local a <close> = nil; a = 1"))))
