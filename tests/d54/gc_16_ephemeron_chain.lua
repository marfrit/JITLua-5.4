--! Ephemeron convergence over a long chain: entry i's value is entry i+1's
--! key, so every key is marked only through the previous entry's value. The
--! chain is built from its tail, and the hash order of the keys is unrelated
--! to the chain order. With its head alive the whole chain survives a full
--! collection; without it, every entry is cleared. The fixpoint is the same
--! whatever order the collector visits the entries in (lgc.c
--! convergeephemerons); tests/bench/ephemeron-chain.lua measures its cost.
local N = 20000
local function build(eph, n)
  local key = {}
  for i = 1, n do
    local k = {}
    eph[k] = key
    key = k
  end
  return key   -- the head: eph[head] -> ... -> the tail key
end

local eph = setmetatable({}, {__mode = "k"})
local head = build(eph, N)
collectgarbage(); collectgarbage()
local n, k = 0, head
while eph[k] ~= nil do n = n + 1; k = eph[k] end
print("chain kept", n)

head, k = nil, nil
collectgarbage(); collectgarbage()
print("chain cleared", next(eph) == nil)

-- two tables, the chain alternating between them
local e1 = setmetatable({}, {__mode = "k"})
local e2 = setmetatable({}, {__mode = "k"})
local key = {}
for i = 1, N do
  local k2 = {}
  if i % 2 == 0 then e1[k2] = key else e2[k2] = key end
  key = k2
end
head = key
collectgarbage(); collectgarbage()
n, k = 0, head
while true do
  local nk = e1[k] or e2[k]
  if nk == nil then break end
  n = n + 1; k = nk
end
print("two-table chain kept", n)
head, k, key = nil, nil, nil
collectgarbage(); collectgarbage()
print("two-table chain cleared", next(e1) == nil, next(e2) == nil)

-- a chain that leads into another ephemeron table found only through it
local outer = setmetatable({}, {__mode = "k"})
local inner = setmetatable({}, {__mode = "k"})
local a, b, c = {}, {}, {}
outer[a] = {inner, b}
inner[b] = c
outer[c] = "end"
collectgarbage()
print("nested ephemeron", outer[a] ~= nil, inner[b] == c, outer[c])
inner, b, c = nil, nil, nil
collectgarbage()
local cnt = 0
for _ in pairs(outer) do cnt = cnt + 1 end
print("nested ephemeron entries", cnt)
