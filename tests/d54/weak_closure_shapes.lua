--! Weak-table JIT loops: closure.lua's exact shape and the local-bound shape,
--! under the default options and with -dce. Bounded and observable: the weak
--! entry must be cleared before the bound on both arms. RED on 7b85747e and
--! 32068a54 (entry stays alive at the bound), GREEN with the stale-slot and
--! GC-drive fix.

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

local function run(label)
  jit.flush()
  local LIMIT = 20000
  local x = setmetatable({[1] = {}}, {__mode = "kv"})
  local n1 = exact(x, LIMIT)
  assert(x[1] == nil, label .. ": exact shape entry not collected (n=" .. n1 .. ")")
  local y = setmetatable({[1] = {}}, {__mode = "kv"})
  local n2 = bound(y, LIMIT)
  assert(y[1] == nil, label .. ": local-bound shape entry not collected (n=" .. n2 .. ")")
  print(label .. ": ok")
end

run("default")
jit.opt.start("-dce")
run("dce")
jit.opt.start()
print("ok")
