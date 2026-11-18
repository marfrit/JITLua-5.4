--! Weak-table JIT loops whose stale value does not sit in the loop-head temp:
--! the read happens in a called function (the value stays in the callee's
--! frame slot), through next() on a weak-keyed table, or the allocation is on
--! a branch that becomes a side trace. Bounded and observable: the weak entry
--! must be cleared before the bound, under the default options and with -dce.

local function chk(t) return t[1] end

local function callee(x, LIMIT)
  local A, n = 0, 0
  while chk(x) and n < LIMIT do
    local a = A..A..A..A
    A = A + 1
    n = n + 1
  end
  return n
end

local function nextkey(x, LIMIT)
  local A, n = 0, 0
  while next(x) and n < LIMIT do
    local a = A..A..A..A
    A = A + 1
    n = n + 1
  end
  return n
end

local function sidealloc(x, LIMIT)
  local A, n = 0, 0
  while x[1] and n < LIMIT do
    if n % 8 == 0 then
      local a = A..A..A..A..A..A..A..A
    end
    A = A + 1
    n = n + 1
  end
  return n
end

local jit = rawget(_G, "jit")

local function run(label)
  local LIMIT = 100000
  if jit then jit.flush() end
  local x = setmetatable({[1] = {}}, {__mode = "v"})
  local n1 = callee(x, LIMIT)
  assert(x[1] == nil, label .. ": callee shape entry not collected (n=" .. n1 .. ")")
  if jit then jit.flush() end
  local y = setmetatable({}, {__mode = "k"})
  y[{}] = true
  local n2 = nextkey(y, LIMIT)
  assert(next(y) == nil, label .. ": next shape key not collected (n=" .. n2 .. ")")
  if jit then jit.flush() end
  local z = setmetatable({[1] = {}}, {__mode = "v"})
  local n3 = sidealloc(z, LIMIT)
  assert(z[1] == nil, label .. ": side-trace allocation shape entry not collected (n=" .. n3 .. ")")
  print(label .. ": ok")
end

run("default")
if jit then jit.opt.start("-dce") end
run("dce")
if jit then jit.opt.start() end
print("ok")
