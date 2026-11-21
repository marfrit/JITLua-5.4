--! Dead stack slots above the live top: a finalizable object overwritten by a
--! constructor/closure must die, while a live local above the reassigned
--! destination must stay alive (the atomic phase nils everything above the
--! top, so an over-narrow top would break 'b').
--! Guards: every waiting loop is bounded by an iteration count, never a timeout.
local function p(...) print(...) end

-- Under a GC-stress run (pause 0) PUC 5.4.9 itself finalizes these objects or
-- not depending on the heap layout of the file, so there only the live-local
-- column is printed; the finalizer outcome is compared at the normal pause.
local stress = (function()
  local prev = collectgarbage("setpause", 200)
  collectgarbage("setpause", prev)
  return prev == 0
end)()
local function pf(label, finish, live, bounded)
  if stress then print(label, live) else print(label, finish, live, bounded) end
end

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

-- The same shape with a constructor that escapes, so the JIT allocates it.
local function t1j()
  local u
  local b
  local finish = false
  u = setmetatable({}, {__gc = function() finish = true end})
  b = {34}
  local keep = {}
  local n = 0
  repeat u = {}; keep[1] = u; n = n + 1 until finish or n > 200000
  return finish, b[1] == 34, n <= 200000
end

-- t1, t5 and j5 allocate only tables that the JIT eliminates (allocation
-- sinking). A compiled loop whose allocations are eliminated does not advance
-- the collector, so under the JIT their finalizer need not run (IMPL-DEFINED,
-- docs/DIFFERENCES.md). They assert the interpreter, which follows PUC; t1j
-- and j5j are the same shapes with an allocation that escapes, so the JIT's
-- dead-slot clearing is asserted as well.
local jit = rawget(_G, "jit")
if jit then jit.off(t1); jit.off(t5) end

pf("t1 table lower local", t1())
pf("t2 concat lower local", t2())
pf("t3 closure lower local", t3())
p("t4 array constructor", t4())
pf("t5 table above", t5())
pf("t6 closure above", t6())
pf("t1j escaping table", t1j())

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
local function j5j()
  local finish = false
  setmetatable({}, {__gc = function() finish = true end})
  local acc, hold = 0, {}
  for i = 1, 40000 do local t = {}; hold[1] = t; acc = acc + i + #t end
  return finish, acc > 0
end

if jit then jit.off(j5) end
do local f, a = j5(); pf("j5 anonymous dead slot", f, a, true) end
do local f, a = j5j(); pf("j5j escaping table", f, a, true) end
