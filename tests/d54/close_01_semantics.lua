--! 5.4 to-be-closed variables, normal-exit paths only (error unwinding is a
--! documented divergence in this port).
local log = {}
local function mk(tag)
  return setmetatable({}, {__close = function(o, e)
    log[#log+1] = tag .. ":" .. tostring(e)
  end})
end
-- Reverse declaration order at scope exit.
do
  local a <close> = mk("a")
  local b <close> = mk("b")
  local c <close> = mk("c")
end
print("scope", table.concat(log, ","))
log = {}
-- Close before returning; the error argument is nil on a normal exit.
local function f()
  local a <close> = mk("f")
  return 7
end
print("return", f(), table.concat(log, ","))
log = {}
-- Break leaves the loop block: that block's variables close, outer ones later.
local function g()
  local a <close> = mk("ga")
  for i = 1, 3 do
    local b <close> = mk("gb" .. i)
    if i == 2 then break end
  end
end
g()
print("break", table.concat(log, ","))
log = {}
-- Nested blocks close innermost first.
do
  local a <close> = mk("o")
  do
    local b1 <close> = mk("i1")
    local b2 <close> = mk("i2")
  end
  local c <close> = mk("o2")
end
print("nested", table.concat(log, ","))
