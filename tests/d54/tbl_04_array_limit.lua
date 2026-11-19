--! modes: B,R
--! The array part's size limit under GC64 follows Lua 5.4: an explicit
--! preallocation above the old 2^27+1 limit must succeed, keep the array part
--! (so the last slot is reachable and #t/t[n] work), and ipairs must stop at
--! the first hole instead of walking the preallocated slots. The final
--! preallocation beyond the new 2^31-1 limit reports "table overflow".
--! LuaJIT-only: PUC has no table.new preload (mode A would fail on the call,
--! not on the array limit), so B and R carry the check.
--! timeout: 120
local p = print
local newtab = require("table.new")

local function ipairstop(t)
  local n = 0
  for i, v in ipairs(t) do
    n = n + 1
    if i > 8 then return "did-not-stop" end
  end
  return n
end

-- At the old limit (asize = 2^27+1): this already worked.
local n1 = 2^27
local t1 = newtab(n1, 0)
t1[n1] = n1
p("below", #t1 == n1, t1[n1] == n1)
t1 = nil
collectgarbage("collect")

-- Just above the old limit (asize = 2^27+2): this must now work too.
local n2 = 2^27+1
local t2 = newtab(n2, 0)
t2[1] = 1
t2[2] = 2
t2[n2] = n2
p("above", #t2 == n2, t2[n2] == n2, ipairstop(t2) == 2)
t2 = nil
collectgarbage("collect")

-- Index the top of an array that grew past the old limit, hot enough for a
-- JIT trace: bounds checks and the 32-bit index compare are unsigned, so an
-- asize of 2^27+2 must keep the array fast paths.
local t3 = newtab(n2, 0)
for i = 1, 20 do t3[i] = i end
local top = n2 - 9
for i = top, n2 do t3[i] = i end
local function segsum(t, lo, hi)
  local s = 0
  for i = lo, hi do s = s + t[i] end
  return s
end
local expected = 0
for i = top, n2 do expected = expected + i end
local acc = 0
for rep = 1, 100 do acc = acc + segsum(t3, top, n2) end
local function segfill(t, lo, hi, v)
  for i = lo, hi do t[i] = v end
end
for rep = 1, 100 do segfill(t3, top, n2, rep % 7) end
p("jit", acc == 100 * expected, t3[top] == 100 % 7, t3[n2] == 100 % 7)
t3 = nil
collectgarbage("collect")

-- One array slot past the new 2^31-1 limit (a = 2^31-1 asks for asize
-- 2^31) must report the overflow, not try to allocate it.
local ok, err = pcall(newtab, 0x7fffffff, 0)
p("limit", ok, tostring(err))
p("done")
