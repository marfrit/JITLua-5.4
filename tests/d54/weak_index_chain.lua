--! modes: B,R
--! A weak table reached through an __index chain is read by the loop like any
--! other table operand: the weak entry must be collected and the loop must
--! end, whether the chain link is weak when the loop is compiled or becomes
--! weak afterwards (a __mode stored into its metatable, a setmetatable on the
--! link). Also covers a weak-valued metatable whose __index table is the only
--! reference. Fails (bounded, no hang) if the trace does not guard the chain.
local jit = rawget(_G, "jit")
local LIMIT = 200000

local function spin(x, limit)
  local n = 0
  while x.k and n < limit do
    local a = ("garbage"):rep(8) .. n
    n = n + 1
  end
  return n
end

local function run(label, mk, mutate)
  if jit then jit.flush() end
  local x, link = mk()
  if mutate then
    spin(x, 2000)                 -- compile while the chain is strong
    mutate(link)
  end
  local n = spin(x, LIMIT)
  assert(x.k == nil and n < LIMIT,
         label .. ": weak entry not collected (n=" .. n .. ")")
  print(label .. ": ok")
end

run("weak-index-target", function()
  local W = setmetatable({k = {}}, {__mode = "v"})
  return setmetatable({}, {__index = W})
end)

run("weak-second-link", function()
  local W = setmetatable({k = {}}, {__mode = "v"})
  local M = setmetatable({}, {__index = W})
  return setmetatable({}, {__index = M})
end)

run("weak-metatable", function()
  local mt = setmetatable({}, {__mode = "v"})
  mt.__index = {k = 1}
  return setmetatable({}, mt)
end)

run("link-gains-mode", function()
  local W = setmetatable({k = {}}, {})
  return setmetatable({}, {__index = W}), W
end, function(W) getmetatable(W).__mode = "v" end)

run("link-setmetatable", function()
  local W = {k = {}}
  return setmetatable({}, {__index = W}), W
end, function(W) setmetatable(W, {__mode = "v"}) end)

run("metatable-gains-mode", function()
  local mt = setmetatable({}, {})
  mt.__index = {k = 1}
  return setmetatable({}, mt), mt
end, function(mt) getmetatable(mt).__mode = "v" end)

print("ok")
