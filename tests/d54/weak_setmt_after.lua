--! setmetatable(x, {__mode='kv'}) after the loop was compiled on a strong x.
--! The trace must exit on the metatable change and re-specialize. Bounded and
--! observable, default options and -dce. RED on 7b85747e and 32068a54,
--! GREEN with the runtime metatable/__mode guard.

local function spin(x, LIMIT)
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
  local x = {[1] = {}}
  spin(x, 2000)  -- compile while x has no metatable
  setmetatable(x, {__mode = "kv"})
  local n = spin(x, 20000)
  assert(x[1] == nil, label .. ": entry not collected after setmetatable (n=" .. n .. ")")
  print(label .. ": ok")
end

run("default")
jit.opt.start("-dce")
run("dce")
jit.opt.start()
print("ok")
