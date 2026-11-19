--! §3.4.1/§3.4.7: 5.4 integer/float arithmetic edges in hot loops. 5.4 keeps
--! an integer result an integer and wraps on overflow (2^63); a float operand
--! makes the rest float. The recorder guards integer arithmetic (ADDOV/SUBOV/
--! MULOV) and exits to the interpreter when it overflows, so the JIT and
--! interpreter must agree at 2^31, 2^53, 2^63 and on mixed int/float and
--! // / % with negatives. Fixed output only.
local function s(name, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(name, table.concat(t, ","))
end
local function ty(x) return math.type(x) or "?" end

-- accumulator crosses int32 in a hot loop (must stay an integer)
local a = 0
for i = 1, 100000 do a = a + i end
s("sum", a, ty(a))

-- accumulator crosses int32 by powers of two (integer wrap in 5.4)
local p = 1
for i = 1, 64 do p = p * 2 end
s("pow2", p, ty(p))

local q = 1
for i = 1, 66 do q = q + q end
s("dbl", q, ty(q))

-- 2^31-1 / 2^31 / -2^31 transitions
local b = 2147483646
for i = 1, 4 do b = b + 1 end
s("up31", b, ty(b))
local c = -2147483648
for i = 1, 3 do c = c - 1 end
s("dn31", c, ty(c))

-- 2^53 exactness
local d = 9007199254740992
for i = 1, 3 do d = d + 1 end
s("p53", d, ty(d))

-- mixed int/float in a hot loop: even iterations integer, odd float
local e = 0
for i = 1, 100000 do
  if i % 2 == 0 then e = e + 1 else e = e + 0.5 end
end
s("mixed", e, ty(e))

-- // and % with negatives, hot
local f, g, h = 0, 0, 0
for i = -100000, 100000 do
  f = f + (i // -7)
  g = g + (i // 7)
  h = h + (i % -7)
end
s("divmod", f, g, h)

-- float accumulator that stays float
local m = 0.0
for i = 1, 100000 do m = m + i * 0.5 end
s("facc", m, ty(m))

-- accumulator that becomes integer after being float
local n = 0.5
for i = 1, 10 do n = n + 0.5 end
s("f2i", n, ty(n))

-- mininteger / maxinteger
local mi = math.mininteger
for i = 1, 3 do mi = mi + 1 end
s("mini", mi, ty(mi))
local ma = math.maxinteger
for i = 1, 3 do ma = ma - 1 end
s("maxi", ma, ty(ma))

-- 2^31-1 * 2^31-1 (int64 result, exceeds... stays integer in 5.4)
local x = 2147483647
local y = 0
for i = 1, 3 do y = y + x * x end
s("mul31", y, ty(y))

-- 2^63-1 via integer ops
local z = 1
for i = 1, 62 do z = z * 2 end
z = z + (z - 1)
s("max63", z == math.maxinteger, ty(z))
