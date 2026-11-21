-- Cost of ephemeron convergence: one weak-key table holding a chain of N
-- entries whose keys are reached only through the previous entry's value,
-- head alive; one full collection is timed.
--   luajit ephemeron-chain.lua [N] [direct|nested]
-- direct: eph[k_i] = k_(i-1); nested: eph[k_i] = {k = {k_(i-1)}} (gc.lua:334).
local N = tonumber(arg and arg[1]) or 20000
local shape = arg and arg[2] or "direct"
local eph = setmetatable({}, {__mode = "k"})
local key = {}
for i = 1, N do
  local k = {}
  if shape == "nested" then eph[k] = {k = {key}} else eph[k] = key end
  key = k
end
local head = key
collectgarbage(); collectgarbage()
local t0 = os.clock()
collectgarbage()
local dt = os.clock() - t0
local n, k = 0, head
while eph[k] ~= nil do
  n = n + 1
  if shape == "nested" then k = eph[k].k[1] else k = eph[k] end
end
assert(n == N, "chain lost entries")
print(string.format("ephemeron-chain %s N=%d fullgc %.4f s", shape, N, dt))
