--! B3: int32 control. Same shapes as B1/B2 but staying inside int32, to show
--! that ordinary code does not regress. Prints "B3 <fnv_ms> <table_ms> <sum>".
local s = ("0123456789abcdef"):rep(655360)

local t0 = os.clock()
local h = 2166136261
local hs = 0
for i = 1, #s do
  h = ((h ~ s:byte(i)) * 16777619) & 0x7fffffff
  hs = (hs + h) & 0x7fffffff
end
local ms1 = (os.clock() - t0) * 1000

local M = 1000000
local t0b = os.clock()
local t = {}
local st = 12345
for i = 1, M do
  st = (st * 1103515245 + 12345) & 0x7fffffff
  t[i] = st
end
local sum = 0
for i = 1, M do sum = (sum + t[i]) & 0x7fffffff end
table.sort(t)
local ms2 = (os.clock() - t0b) * 1000

print(string.format("B3 %.1f %.1f %s", ms1, ms2, tostring(sum)))
