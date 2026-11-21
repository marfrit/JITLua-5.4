--! Dead-slot clearing at a compiled loop head must keep every slot whose old
--! value is still read: by code before the loop that an enclosing loop runs
--! again, or by a closure created after the loop (an upvalue read is not an
--! operand of any bytecode). The inner loops allocate, so their traces carry
--! a GC check at the loop head; the conditional store never happens.
local function p(...) print(...) end

-- read only before the inner loop, in the enclosing loop
local function r1()
  local x = {"keep"}
  local bad = 0
  for k = 1, 300 do
    if x == nil or x[1] ~= "keep" then bad = bad + 1 end
    local j = 0
    while j < 300 do
      local t = {}
      if j < 0 then x = t end
      j = j + 1
    end
  end
  return bad
end

-- read only by a closure created after the loop
local function r2()
  local x = {"keep"}
  local j = 0
  while j < 300000 do
    local t = {}
    if j < 0 then x = t end
    j = j + 1
  end
  local f = function() return x end
  local v = f()
  return v ~= nil and v[1]
end

-- the same with a numeric for loop and a read in the enclosing while loop
local function r3()
  local x = {"keep"}
  local bad, k = 0, 0
  while k < 300 do
    k = k + 1
    if x == nil or x[1] ~= "keep" then bad = bad + 1 end
    for i = 1, 300 do
      local t = {i}
      if i < 0 then x = t end
      t = nil
    end
  end
  return bad
end

-- a slot that the loop really overwrites and nobody reads: still collected
local function r4()
  local u
  local finish = false
  u = setmetatable({}, {__gc = function() finish = true end})
  local keep = {34}
  local n = 0
  repeat u = {}; n = n + 1 until finish or n > 200000
  return finish, keep[1] == 34, n <= 200000
end

p("r1 read in enclosing loop", r1())
p("r2 read by later closure", r2())
p("r3 for loop, enclosing read", r3())
p("r4 overwritten slot dies", r4())
