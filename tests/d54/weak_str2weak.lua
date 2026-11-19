--! Strong-then-weak through one shared bytecode loop: a trace compiled while
--! the table was strong must exit on the weak table and re-specialize.
--! Bounded and observable, default options and -dce. RED on 7b85747e and
--! 32068a54, GREEN with the runtime metatable/__mode guard.

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
  local strong = {[1] = {}}
  local weak = setmetatable({[1] = {}}, {__mode = "kv"})
  spin(strong, 2000)  -- compile the loop against a strong table
  local n = spin(weak, 20000)
  assert(weak[1] == nil, label .. ": weak table entry not collected (n=" .. n .. ")")
  print(label .. ": ok")
end

run("default")
if jit then jit.opt.start("-dce") end
run("dce")
if jit then jit.opt.start() end
print("ok")
