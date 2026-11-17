local random, max, min = math.random, math.max, math.min
local function aux (x1, x2)
  local mark = {}; local count = 0
  while true do
    local t = random(x1, x2)
    assert(x1 <= t and t <= x2)
    if not mark[t] then
      mark[t] = true; count = count + 1
      if count == x2 - x1 + 1 then goto ok end
    end
  end
  ::ok::
end
aux(1, 32)
aux(1, 33)
aux(-10, 10)
print("REPRO-END")
