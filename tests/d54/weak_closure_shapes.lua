--! Weak-table JIT loops: closure.lua's exact shape and the local-bound shape,
--! under the default options and with -dce. Bounded and observable: the weak
--! entry must be cleared before the bound on both arms. RED on 7b85747e and
--! 32068a54 (entry stays alive at the bound), GREEN with the stale-slot and
--! GC-drive fix.
-- The bounds in this test are sized for a collector pause of 200. Pin it, so
-- the result does not depend on the default GC policy; a lower pause (the
-- harness's GC-stress arm) is kept.
do
  local prev = collectgarbage("setpause", 200)
  if prev < 200 then collectgarbage("setpause", prev) end
end

local function exact(x, LIMIT)
  local A, n = 0, 0
  while x[1] do
    if n >= LIMIT then break end
    local a = A..A..A..A
    A = A + 1
    n = n + 1
  end
  return n
end

local function bound(x, LIMIT)
  local A, n = 0, 0
  while x[1] and n < LIMIT do
    local a = A..A..A..A
    A = A + 1
    n = n + 1
  end
  return n
end

local jit = rawget(_G, "jit")

local function run(label)
  if jit then jit.flush() end
  -- The loop drives the GC by allocation, so a larger pause needs more
  -- iterations: the bound holds for the pause pinned above (it is too small
  -- from about twice that) and still fails if the entry is never collected.
  local LIMIT = 100000
  local x = setmetatable({[1] = {}}, {__mode = "kv"})
  local n1 = exact(x, LIMIT)
  assert(x[1] == nil, label .. ": exact shape entry not collected (n=" .. n1 .. ")")
  local y = setmetatable({[1] = {}}, {__mode = "kv"})
  local n2 = bound(y, LIMIT)
  assert(y[1] == nil, label .. ": local-bound shape entry not collected (n=" .. n2 .. ")")
  print(label .. ": ok")
end

run("default")
if jit then jit.opt.start("-dce") end
run("dce")
if jit then jit.opt.start() end
print("ok")
