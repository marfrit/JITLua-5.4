--! modes: A,B
--! timeout: 120
-- A wide integer for loop must not let the heap grow with its iteration
-- count. PUC 5.4.9 (lvm.c OP_FORLOOP) allocates nothing per iteration; here
-- a control value outside the inline integer range is an interned box, so
-- the loop allocates, and it must step the collector like any allocating
-- code. A value inside the inline 47-bit range allocates nothing.
-- Prints booleans only: the heap sizes themselves differ by design.

local LIMIT = 64 * 1024   -- KB of growth tolerated (the collector's pace)

local function grows(name, f)
  collectgarbage(); collectgarbage()
  local before = collectgarbage("count")
  local peak = before
  f(function()
    local c = collectgarbage("count")
    if c > peak then peak = c end
  end)
  print(name, peak - before < LIMIT)
end

-- Boxed control values (outside the 47-bit inline range).
grows("boxed asc", function(probe)
  local n = 0
  for i = 1 << 50, (1 << 50) + 3000000 do
    n = n + 1
    if n % 100000 == 0 then probe() end
  end
  probe()
end)
grows("boxed desc", function(probe)
  local n = 0
  for i = math.mininteger + 3000000, math.mininteger, -1 do
    n = n + 1
    if n % 100000 == 0 then probe() end
  end
  probe()
end)
-- Inline 47-bit control values: nothing to collect.
grows("inline", function(probe)
  local n = 0
  for i = 1 << 40, (1 << 40) + 3000000 do
    n = n + 1
    if n % 100000 == 0 then probe() end
  end
  probe()
end)
-- A huge limit with an index in the int32 range.
grows("huge", function(probe)
  local n = 0
  for i = 1, math.huge do
    n = n + 1
    if n % 100000 == 0 then probe() end
    if n >= 3000000 then break end
  end
  probe()
end)
-- Many short wide loops: every loop start must be paid for, too.
grows("starts", function(probe)
  local n = 0
  for k = 1, 300000 do
    for i = (1 << 50) + k, (1 << 50) + k + 1 do n = n + 1 end
    if k % 10000 == 0 then probe() end
  end
  probe()
end)
