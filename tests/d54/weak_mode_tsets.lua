--! mt.__mode = "kv" through the VM TSETS fast path after compile: the table
--! setter resets the MM_mode negative cache, so the runtime guard must exit
--! and re-specialize. Bounded and observable, default options and -dce.
--! RED on 7b85747e and 32068a54, GREEN with the runtime metatable/__mode guard.
--! modes: B,R  (PUC keeps the pre-__mode value alive in a temp slot)
-- The bounds in this test are sized for a collector pause of 200. Pin it, so
-- the result does not depend on the default GC policy; a lower pause (the
-- harness's GC-stress arm) is kept.
do
  local prev = collectgarbage("setpause", 200)
  if prev < 200 then collectgarbage("setpause", prev) end
end

local function spin(x, LIMIT)
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
  local mt = {}
  local x = setmetatable({[1] = {}}, mt)
  spin(x, 2000)  -- compile with an mt that has no __mode
  mt.__mode = "kv"
  local n = spin(x, 20000)
  assert(x[1] == nil, label .. ": entry not collected after mt.__mode (n=" .. n .. ")")
  print(label .. ": ok")
end

run("default")
if jit then jit.opt.start("-dce") end
run("dce")
if jit then jit.opt.start() end
print("ok")
