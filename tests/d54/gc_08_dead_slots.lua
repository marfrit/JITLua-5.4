--! Dead stack slots above the live top: a finalizable object overwritten by a
--! constructor/closure must die, while a live local above the reassigned
--! destination must stay alive (the atomic phase nils everything above the
--! top, so an over-narrow top would break 'b').
--! Guards: every waiting loop is bounded by an iteration count, never a timeout.
local function p(...) print(...) end

-- GC1 shape, table constructor into the lower local 'u', 'b' live above it.
local function t1()
  local u
  local b
  local finish = false
  u = setmetatable({}, {__gc = function() finish = true end})
  b = {34}
  local n = 0
  repeat u = {}; n = n + 1 until finish or n > 200000
  return finish, b[1] ~= nil and b[1] == 34, n <= 200000
end

-- string concat into 'u'
local function t2()
  local u
  local b
  local finish = false
  u = setmetatable({}, {__gc = function() finish = true end})
  b = {34}
  local n = 0
  local i = 1
  repeat i = i + 1; u = tostring(i) .. tostring(i); n = n + 1
  until finish or n > 200000
  return finish, b[1] == 34, n <= 200000
end

-- closure into 'u'
local function t3()
  local u
  local b
  local finish = false
  u = setmetatable({}, {__gc = function() finish = true end})
  b = {34}
  local n = 0
  repeat local i; u = function() return i end; n = n + 1
  until finish or n > 200000
  return finish, b[1] == 34, n <= 200000
end

-- GC2 shape, the finalizable table is inside an array constructor. Only the
-- live local is compared: under a setpause-0 stress run PUC itself keeps this
-- object past the bound or not depending on the heap layout, so whether the
-- loop ended by the finalizer is not stable on the reference side.
local function t4()
  local u
  local finish = false
  u = {setmetatable({}, {__gc = function() finish = true end})}
  local b = {34}
  local n = 0
  repeat u = {{}}; n = n + 1 until finish or n > 200000
  return b[1] == 34
end

-- constructor into a local declared before the live value above it
local function t5()
  local x
  local b = {34}
  local finish = false
  x = setmetatable({}, {__gc = function() finish = true end})
  local n = 0
  repeat x = {}; n = n + 1 until finish or n > 200000
  return finish, b[1] == 34, n <= 200000
end

-- closure into a local declared before the live value above it
local function t6()
  local x
  local b = {34}
  local finish = false
  x = setmetatable({}, {__gc = function() finish = true end})
  local n = 0
  repeat x = function() return 1 end; n = n + 1 until finish or n > 200000
  return finish, b[1] == 34, n <= 200000
end

p("t1 table lower local", t1())
p("t2 concat lower local", t2())
p("t3 closure lower local", t3())
p("t4 array constructor", t4())
p("t5 table above", t5())
p("t6 closure above", t6())

-- Semantics of values across a GC check at a loop head (JIT and interpreter).
local function j1()
  local acc = 0
  local b = {42}
  for i = 1, 20000 do
    local t = {}
    acc = acc + i + (#t == 0 and 0 or 0)
  end
  return b[1], acc
end

local function j2()
  local last
  for i = 1, 20000 do last = i end
  return last
end

local function j3()
  local fs = {}
  for i = 1, 20000 do fs[1] = function() return i end end
  return fs[1]()
end

local function j4()
  local n = 0
  repeat
    local a = {}
    n = n + 1
  until n >= 20000 or a == nil
  return n
end

local function j5()
  local finish = false
  setmetatable({}, {__gc = function() finish = true end})
  local acc = 0
  for i = 1, 40000 do local t = {}; acc = acc + i + #t end
  return finish, acc > 0
end

p("j1 live local above", j1())
p("j2 loop control", j2())
p("j3 capture in loop", j3())
p("j4 repeat body local", j4())
p("j5 anonymous dead slot", j5())
