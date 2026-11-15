--! B2b (Markus addendum 2): a table of 1e6 ms-timestamp-sized values (~2^41).
--! This is what "47-bit inline integers" would buy: values in the 2^41 range fit
--! inline and lose their boxes. With a 32-bit inline model every element is a
--! box; with double-only (stock LuaJIT) every element is a double.
--! Prints "B2b <ms> <checksum> <mode> <alloc_KB>".
local mi = math.maxinteger
local has64 = mi ~= nil and (mi + 1) == math.mininteger
local N = 1000000
local before = collectgarbage("count")

local t0 = os.clock()
local t = {}
local base = 1700000000000  -- 2023-11-14 in ms, ~2^41
for i = 1, N do
  t[i] = base + i
end
local sum = 0
for i = 1, N do sum = sum + t[i] end
table.sort(t)
local ms = (os.clock() - t0) * 1000
print(string.format("B2b %.1f %s %s %.0f", ms,
  tostring(sum % 1000007), has64 and "int64" or "float",
  collectgarbage("count") - before))
