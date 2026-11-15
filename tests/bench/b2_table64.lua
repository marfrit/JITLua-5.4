--! B2: a table of 1e6 64-bit values -- fill with xorshift64, read+sum, sort.
--! Plain-integer variant. This is the "big ints in memory" case: every element
--! is a box (plus an intern lookup) until the JIT sinks them.
--! Prints "B2 <ms> <checksum> <mode> <alloc_KB>".

local mi = math.maxinteger
local has64 = mi ~= nil and (mi + 1) == math.mininteger

if os.getenv("BENCH_FFI") == "1" then
  local f = assert(loadfile("tests/bench/b2_table64_ffi.lua"))
  return f()
end
if not has64 then
  print("B2 0 0 unsupported 0")
  os.exit(0)
end

local N = 1000000
local before = collectgarbage("count")

local t0 = os.clock()
local t = {}
local st = 0x9e3779b97f4a7c15
for i = 1, N do
  st = st ~ (st << 13)
  st = st ~ (st >> 7)
  st = st ~ (st << 17)
  t[i] = st
end
local sum = 0
for i = 1, N do sum = sum + t[i] end
table.sort(t, function(a, b) return a < b end)
local ms = (os.clock() - t0) * 1000
print(string.format("B2 %.1f %s int64 %.0f", ms,
  tostring(sum & 0xffffffff), collectgarbage("count") - before))
