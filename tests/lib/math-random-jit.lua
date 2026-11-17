-- Regression: x64 JIT with negative int32 table keys produced by the checked
-- int64->int32 CONV (math.random(lo, up) in a trace). The CONV left the sign
-- extension in the register; HREF and NEWREF (asm_tvptr) OR-ed the type tag
-- into the 64-bit register, so negative keys became nil-tagged garbage and
-- lj_tab_newkey's collision-chain walk crashed or hung. Known-bad "math B".
-- Self-checking: the interpreter must see every key the trace stored.
local random = math.random

local function fill(x1, x2)
  local mark, count = {}, 0
  while true do
    local t = random(x1, x2)
    assert(x1 <= t and t <= x2)
    if not mark[t] then
      mark[t] = true; count = count + 1
      if count == x2 - x1 + 1 then break end
    end
  end
  return mark
end

math.randomseed(1234)
for _ = 1, 20 do
  for _, r in ipairs({{-40, -1}, {-10, 10}, {1, 32}, {-100, -60}}) do
    local lo, up = r[1], r[2]
    local mark = fill(lo, up)
    local n = 0
    for k, v in pairs(mark) do
      assert(math.type(k) == "integer" and lo <= k and k <= up and v == true,
             "bad key " .. tostring(k))
      n = n + 1
    end
    assert(n == up - lo + 1, "key count " .. n .. " for " .. lo .. ".." .. up)
    for k = lo, up do assert(mark[k] == true, "missing key " .. k) end
  end
end

-- Negative int32 key through a trace, stored and read back in the interpreter.
local acc = {}
for i = 1, 2000 do
  local k = random(-50, -1)
  acc[k] = (acc[k] or 0) + 1
end
local total = 0
for k = -50, -1 do total = total + (acc[k] or 0) end
assert(total == 2000, "lost stores: " .. total)
print("math-random-jit OK")
