--! B1: FNV-1a 64-bit over a 10 MB string -- a register-resident 64-bit loop.
--! Plain-integer variant (PUC 5.4.7, and our build once the value model carries
--! 64-bit integers). Prints "B1 <ms> <checksum> <mode>"; mode "unsupported"
--! means the integer model has no 64-bit range, so the number is not
--! comparable to the FFI yardstick (stock LuaJIT 2.1 uses b1_fnv_ffi.lua).
--! Nothing here uses 5.4-only syntax, so stock 2.1 can parse it too.

local mi = math.maxinteger
local has64 = mi ~= nil and (mi + 1) == math.mininteger

if os.getenv("BENCH_FFI") == "1" then
  local f = assert(loadfile("tests/bench/b1_fnv_ffi.lua"))
  return f()
end
if not has64 then
  print("B1 0 0 unsupported")
  os.exit(0)
end

local s = ("0123456789abcdef"):rep(655360)  -- 10 MiB

local t0 = os.clock()
local h = 0xcbf29ce484222325
local prime = 0x100000001b3
local hs, cs = 0, 0
for i = 1, #s do
  h = (h ~ s:byte(i)) * prime   -- wraps mod 2^64 in 5.4
  hs = hs + h
  cs = cs + (h & 0xffff)
end
local ms = (os.clock() - t0) * 1000
print(string.format("B1 %.1f %s int64", ms, tostring(cs)))
