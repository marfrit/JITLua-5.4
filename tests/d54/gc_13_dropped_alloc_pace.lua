--! Allocations that a compiled loop drops (sunk constructors, unused strings)
--! must still move the collector, as PUC allocates them: a loop that only
--! makes such garbage and waits for a finalizer has to end. The finalizable
--! object is created in a helper, so no stack slot of the loop's frame
--! refers to it. Guards: iteration counts, never a timeout.
local function p(...) print(...) end

local function arm(flag)
  setmetatable({}, {__gc = function() flag.done = true end})
end

-- sinkable constructor: the table never escapes
local function s1()
  local flag = {done = false}
  arm(flag)
  local n, acc = 0, 0
  repeat
    local v = {x = 1, y = 2}
    acc = acc + v.x + v.y
    n = n + 1
  until flag.done or n > 3000000
  return flag.done, n <= 3000000, acc > 0
end

-- dead string results
local function s2()
  local flag = {done = false}
  arm(flag)
  local n = 0
  repeat
    local s = "k" .. n
    n = n + 1
  until flag.done or n > 3000000
  return flag.done, n <= 3000000
end

-- sinkable array constructor in a numeric for loop
local function s3()
  local flag = {done = false}
  arm(flag)
  local acc = 0
  for i = 1, 3000000 do
    local v = {i, i + 1}
    acc = acc + v[2] - v[1]
    if flag.done then return true, acc > 0 end
  end
  return false, acc > 0
end

p("s1 sunk table", s1())
p("s2 dead string", s2())
p("s3 sunk array", s3())
