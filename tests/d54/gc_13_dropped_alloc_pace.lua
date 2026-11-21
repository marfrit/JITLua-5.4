--! Loops that allocate only garbage (a non-escaping constructor, an unused
--! string) and wait for a finalizer. PUC allocates every object, so the
--! collector runs and each loop ends; the interpreter does the same. A
--! compiled loop whose allocations the JIT eliminates (allocation sinking,
--! dead-code elimination) does not advance the collector, so under the JIT
--! such a loop need not end (IMPL-DEFINED, docs/DIFFERENCES.md): the asserted
--! run is the interpreter's, the compiled run only shows that the bounded
--! loops return. The finalizable object is created in a helper, so no stack
--! slot of the loop's frame refers to it. Guards: iteration counts, never a
--! timeout.
local function p(...) print(...) end

local function arm(flag)
  setmetatable({}, {__gc = function() flag.done = true end})
end

-- Loaded twice: jit.off marks a prototype, and the compiled run needs its own.
local src = [[
local arm = ...

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

return s1, s2, s3
]]

local s1, s2, s3 = load(src)(arm)
local c1, c2, c3 = load(src)(arm)
local jit = rawget(_G, "jit")
if jit then jit.off(s1); jit.off(s2); jit.off(s3) end

p("s1 sunk table", s1())
p("s2 dead string", s2())
p("s3 sunk array", s3())

-- Compiled run (when there is a JIT): whether the finalizer ran is not asserted.
local function ended(f) f(); return true end
p("bounded loops return", ended(c1), ended(c2), ended(c3))
