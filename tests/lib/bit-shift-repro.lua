-- Minimal arm64 bit-shift repro. Stock LuaJIT 2.1-compatible.
-- INT32_MIN is computed as -2147483647-1 to avoid the negative-literal parse trap.
local min32 = -2147483647 - 1
local ok = bit.lshift(1, 0) == 1 and bit.lshift(1, 1) == 2
  and bit.lshift(1, 31) == min32
  and bit.rshift(-1, 31) == 1 and bit.arshift(-1, 1) == -1
  and bit.rol(1, 1) == 2 and bit.ror(1, 1) == min32
local F = require("ffi")
local c = bit.lshift(F.new("int64_t", 1), 63)
local cok = tostring(c) == "-9223372036854775808LL"
print("shift-ok", ok, bit.lshift(1, 0), bit.lshift(1, 1), bit.lshift(1, 31),
  bit.rshift(-1, 31), bit.arshift(-1, 1), bit.rol(1, 1), bit.ror(1, 1),
  tostring(c), cok)
if not (ok and cok) then os.exit(1) end
