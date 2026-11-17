-- int32-overflowing arithmetic inside a bit-op masked expression.
-- Lua 5.4 semantics: * and + wrap modulo 2^64, then the mask applies to the
-- 64-bit result. A JIT that narrows to int32/float must produce the same value
-- as the interpreter (mode B vs A) and as PUC 5.4.9.
local st = 12345
for i = 1, 100000 do
  st = (st * 1103515245 + 12345) & 0x7fffffff
end
print("lcg", st)                      -- PUC: 1196193376

local function run(n, seed, mul, inc, mask)
  local s = seed
  for i = 1, n do s = (s * mul + inc) & mask end
  return s, math.type(s)
end
print("r1", run(1000, 1, 0x7fffffff, 1, 0xffffffff))   -- overflow on every step
print("r2", run(1000, -5, 0x100000001b3, 7, 0x7fffffff))
print("r3", run(100, 1 << 20, 1 << 40, 1 << 35, 0x7fffffff))
print("r4", run(100, 3, 0x40000001, 0x7fffffff, 0x7fffffff))

-- Unmasked overflow in a hot loop: the value widens, and the result must be
-- the 64-bit wrapped product, not a float or a 32-bit wrap.
local p = 0
local s = 1 << 30
for i = 1, 200000 do p = p + s; s = s * 0x1b3 end
print("wide", p, math.type(p))

-- int32-safe control (must stay fast and correct)
local c = 0
for i = 1, 1000000 do c = (c * 1103515245 + 12345) & 0x3fffffff end
print("safe", c)
