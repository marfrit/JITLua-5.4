--! B2 (FFI variant for stock LuaJIT 2.1): a table of 1e6 uint64_t cdata --
--! fill with xorshift64, read+sum, sort. This is the "64-bit values in memory"
--! yardstick: FFI cdata are heap objects there, comparable to boxes.
local ffi = require("ffi")
ffi.cdef[[typedef unsigned long long uint64_t;]]

local N = 1000000
local before = collectgarbage("count")

local t0 = os.clock()
local t = {}
local st = ffi.new("uint64_t", 0x9e3779b97f4a7c15ULL)
for i = 1, N do
  st = st ~ (st << 13)
  st = st ~ (st >> 7)
  st = st ~ (st << 17)
  t[i] = st
end
local sum = ffi.new("uint64_t", 0)
for i = 1, N do sum = sum + t[i] end
table.sort(t, function(a, b) return a < b end)
local ms = (os.clock() - t0) * 1000
print(string.format("B2 %.1f %s ffi %.0f", ms,
  tostring(tonumber(sum & 0xffffffff)), collectgarbage("count") - before))
