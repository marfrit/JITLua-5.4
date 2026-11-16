--! §4.1 64-bit integers in traces (ADR-001b step 3). Every loop below is hot
--! enough to be compiled; mode B compares the JIT against the interpreter and
--! mode A the interpreter against PUC 5.4.7, so the printed values pin down
--! the int64 IR paths: int64 slots (widened inline and boxed), int32 -> int64
--! widening on overflow, narrowing back to int32, loop PHIs of both kinds,
--! trace exits with int64 live values and constants, trace tails that store
--! int64 slots, 64-bit shifts, comparisons and mixed int/float arithmetic.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = (select(i, ...))
    t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end

-- FNV-1a 64-bit: int64 from loop entry (boxed literal), xor/mul wrap.
local s = ("The quick brown fox jumps over the lazy dog"):rep(64)
local h, hs, cs = 0xcbf29ce484222325, 0, 0
for i = 1, #s do
  h = (h ~ s:byte(i)) * 0x100000001b3
  hs = hs + h
  cs = cs + (h & 0xffff)
end
p("fnv", h, hs, cs)

-- LCG: int32 slots, int64 intermediates, mask narrows back to int32.
local st, acc = 12345, 0
for i = 1, 20000 do
  st = (st * 1103515245 + 12345) & 0x7fffffff
  acc = (acc + st) & 0x7fffffff
end
p("lcg", st, acc)

-- Accumulator crosses 2^31 while the loop runs (int -> int64 PHI).
local a = 0
for i = 1, 3000 do a = a + 1000000 end
p("cross-up", a)

-- Starts wide, comes back into int32 range (int64 -> int PHI).
local b = 1 << 40
for i = 1, 3000 do b = b - (1 << 29) end
p("cross-down", b)

-- Slot alternates between the widened and the boxed representation.
local w, cnt = 1 << 40, 0
for i = 1, 2000 do
  w = (w == (1 << 40)) and (1 << 60) or (1 << 40)
  cnt = cnt + (w >> 40)
end
p("alternate", w, cnt)

-- Values in [2^31, 2^32) (boxed band), around 2^47 and the extremes.
local band, x47, mx, mn = 0, 0, math.maxinteger, math.mininteger
for i = 1, 1000 do
  band = 2147483648 + (i & 7)
  x47 = (1 << 47) + i
  mx = mx - 1 + 1
  mn = mn + 1 - 1
end
p("bands", band, x47, mx, mn, mx + 1 == mn, -mn == mn)

-- Shifts: constant counts in all four regimes, then variable counts.
local sh1, sh2, sh3, sh4, sh5, sh6 = 0, 0, 0, 0, 0, 0
for i = 1, 1000 do
  sh1 = 1 << 40
  sh2 = (1 << 62) >> 61
  sh3 = 1 << 64
  sh4 = -1 >> 1
  sh5 = 8 << -2
  sh6 = (1 << 40) >> -3
end
p("shift-k", sh1, sh2, sh3, sh4, sh5, sh6)
local vs, vt = 0, 0
for i = 0, 140 do
  local n = (i % 70) - 2
  vs = vs ~ ((0x9e3779b97f4a7c15 << n) >> 1)
  vt = vt + (1 << n)
end
p("shift-v", vs, vt)

-- Unary minus on all three kinds of integer.
local u1, u2, u3, u4 = 0, 0, 0, 0
local m31 = -2147483648
for i = 1, 1000 do
  u1 = -m31
  u2 = -(1 << 40)
  u3 = -math.mininteger
  u4 = -0
end
p("unm", u1, u2, u3, u4)

-- Comparisons int64 vs int64 and int64 vs int32 in both orders.
local lt, le, gt, eq, ne = 0, 0, 0, 0, 0
local big = 1 << 50
for i = 1, 2000 do
  local v = (i & 1 == 0) and big or -big
  if v < 7 then lt = lt + 1 end
  if 7 <= v then le = le + 1 end
  if v > big - 1 then gt = gt + 1 end
  if v == big then eq = eq + 1 end
  if v ~= 7 then ne = ne + 1 end
end
p("cmp", lt, le, gt, eq, ne)

-- Equality across representations: widened vs widened with equal low words,
-- box literal vs computed value, int32 vs widened, integers vs equal floats.
local e1, e2, e3, e4, e5, e6, e7 = 0, 0, 0, 0, 0, 0, 0
for i = 1, 1000 do
  local w1, w2 = (1 << 40) + 5, (1 << 41) + 5
  local bx = 0x7fffffffffffffff
  if w1 == w2 then e1 = e1 + 1 end
  if w1 ~= 5 then e2 = e2 + 1 end
  if bx == math.maxinteger then e3 = e3 + 1 end
  if (1 << 40) == 1099511627776 then e4 = e4 + 1 end
  if w1 == 1099511627781.0 then e5 = e5 + 1 end
  if bx ~= 9.2233720368547758e18 then e6 = e6 + 1 end
  if 2147483648 == (1 << 31) then e7 = e7 + 1 end
end
p("eq", e1, e2, e3, e4, e5, e6, e7)

-- Mixed arithmetic: float operands, '/', '^', '%' with negative divisors.
local f1, f2, f3, f4, f5, f6 = 0, 0, 0, 0, 0, 0
for i = 1, 1000 do
  f1 = (1 << 40) + 0.5
  f2 = (1 << 40) / 2
  f3 = (1 << 40) ^ 1
  f4 = (1 << 40) % 7
  f5 = (1 << 40) % -7
  f6 = math.mininteger % -1
end
p("mixed", f1, f2, f3, f4, f5, f6)

-- A compiled function returning an int64 (trace tail stores the slot) and a
-- loop exit with int64 values live in registers and as constants.
local function mix(v) return v * 6364136223846793005 + 1442695040888963407 end
local r, last = 1, 0
for i = 1, 2000 do
  r = mix(r)
  if i == 1999 then last = 0x7fffffffffffffff end
end
p("ret", r, last)

-- int64 through tables and upvalues (interpreter paths today): the values
-- must still agree.
local t, sum = {}, 0
for i = 1, 500 do t[i] = (1 << 40) * i end
for i = 1, 500 do sum = sum + t[i] end
local up = 1 << 45
local function bump() up = up + 1 end
for i = 1, 300 do bump() end
p("tab-up", sum, up, t[250])
