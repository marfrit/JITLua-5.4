--! B5: hot loop with pcall/xpcall. The C-call nesting bound must not stop
--! these traces from compiling. Prints "B5 <pcall_ms> <xpcall_ms> <sum>".
local function f(x) return x + 1 end
local function h(err) return err end
local N = 2000000

local t0 = os.clock()
local s = 0
for i = 1, N do
  local ok, v = pcall(f, i)
  s = s + v
end
local ms1 = (os.clock() - t0) * 1000

local t1 = os.clock()
for i = 1, N do
  local ok, v = xpcall(f, h, i)
  s = s + v
end
local ms2 = (os.clock() - t1) * 1000

print(string.format("B5 %.1f %.1f %s", ms1, ms2, tostring(s)))
