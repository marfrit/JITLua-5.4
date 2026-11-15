--! B1 (FFI variant for stock LuaJIT 2.1): FNV-1a 64-bit over a 10 MB string
--! using FFI uint64_t, i.e. the yardstick for a register-resident 64-bit loop.
--! Loaded with loadfile() only by the arm that sets BENCH_FFI=1, so this file's
--! ULL literals never reach a plain Lua parser.
local ffi = require("ffi")
ffi.cdef[[typedef unsigned long long uint64_t;]]

local N = 16 * 655360  -- 10 MiB, exact multiple of the 16-byte chunk
local s = ("0123456789abcdef"):rep(655360)

local t0 = os.clock()
local h = ffi.new("uint64_t", 0xcbf29ce484222325ULL)
local prime = ffi.new("uint64_t", 0x100000001b3ULL)
local hs = ffi.new("uint64_t", 0)
local cs = ffi.new("uint64_t", 0)
for i = 1, #s do
  local b = ffi.new("uint64_t", s:byte(i))
  h = (h ~ b) * prime
  hs = hs + h
  cs = cs + (h & 0xffff)
end
local ms = (os.clock() - t0) * 1000
print(string.format("B1 %.1f %s ffi", ms, tostring(tonumber(cs))))
