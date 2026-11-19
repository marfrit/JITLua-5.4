--! B4: constructor loop with a __gc-free metatable (5.4 table finalizers).
--! setmetatable must stay recordable: run with -jv and check that the trace
--! does not abort or stitch at setmetatable. Prints "B4 <ms> <sum>".
local mt = {tag = "M"}
local N = 2000000

local t0 = os.clock()
local s = 0
for i = 1, N do
  local o = setmetatable({}, mt)
  o.v = i
  s = s + o.v
end
local ms = (os.clock() - t0) * 1000

print(string.format("B4 %.1f %s", ms, tostring(s)))
