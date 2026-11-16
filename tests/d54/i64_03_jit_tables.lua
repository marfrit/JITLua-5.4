--! §4.1 64-bit integers in traces, part 2: int64 values through tables
--! (array and hash parts, both representations), upvalues, varargs and
--! pairs(); int64 vs float compares and equality; floor division; fast
--! functions with int64 arguments. Mode A compares with PUC, mode B the JIT
--! with the interpreter.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = (select(i, ...))
    t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end

-- Array part: widened (2^41 range) and boxed (xorshift64) values.
local N = 4000
local t, sum = {}, 0
local base = 1700000000000
for i = 1, N do t[i] = base + i end
for i = 1, N do sum = sum + t[i] end
p("arr-widened", sum, t[1], t[N], math.type(t[N]))
local st = 0x9e3779b97f4a7c15
local u, acc = {}, 0
for i = 1, N do
  st = st ~ (st << 13); st = st ~ (st >> 7); st = st ~ (st << 17)
  u[i] = st
end
for i = 1, N do acc = acc + u[i] end
p("arr-boxed", acc & 0xffffffff, u[7])

-- Hash part with string keys, mixed representations per slot over time.
local h = {}
for i = 1, 2000 do
  h.a = (i & 1 == 0) and (1 << 40) + i or (1 << 60) + i
  h.b = i
  h.c = h.a + h.b
end
p("hash", h.a, h.b, h.c)

-- A slot that alternates int32 / widened / boxed across iterations.
local m, cnt = {}, 0
for i = 1, 3000 do
  local r = i % 3
  m[1] = (r == 0) and i or (r == 1) and (1 << 40) + i or (1 << 60) + i
  if m[1] > 1000 then cnt = cnt + 1 end
end
p("alternating", m[1], cnt)

-- Upvalues: load and store of int64 through closures.
local up = 1 << 45
local function bump(d) up = up + d; return up end
local last
for i = 1, 2000 do last = bump(i) end
p("upvalue", up, last)

-- Varargs carrying int64.
local function vsum(...)
  local s = 0
  for i = 1, select("#", ...) do s = s + (select(i, ...)) end
  return s, ...
end
local vs
for i = 1, 1000 do vs = vsum(1 << 40, 1 << 50, i) end
p("vararg", vs)

-- pairs over int64 values.
local q = {}
for i = 1, 64 do q[i] = (1 << 33) * i end
local ps = 0
for k = 1, 200 do for _, v in pairs(q) do ps = ps + v end end
p("pairs", ps)

-- int64 vs float compares, both orders, with equality and NaN.
local lt, ge, le, gt, eq, ne, nn = 0, 0, 0, 0, 0, 0, 0
local w, big = 1 << 40, 2^62
local nan = 0/0
for i = 1, 1000 do
  if w < 1099511627776.5 then lt = lt + 1 end
  if 1099511627776.5 >= w then ge = ge + 1 end
  if w <= 1099511627776.0 then le = le + 1 end
  if big > w then gt = gt + 1 end
  if w == 1099511627776.0 then eq = eq + 1 end
  if w ~= 1099511627776.5 then ne = ne + 1 end
  if w < nan or w > nan or w == nan then nn = nn + 1 end
end
p("cmpnum", lt, ge, le, gt, eq, ne, nn)

-- Floor division on int32, int64 and float operands.
local d1, d2, d3, d4, d5 = 0, 0, 0, 0, 0
for i = 1, 1000 do
  d1 = (7 * i) // 3
  d2 = (-7 * i) // 3
  d3 = (1 << 40) // -3
  d4 = math.mininteger // -1
  d5 = 7.5 // 2
end
p("idiv", d1, d2, d3, d4, d5)

-- Fast functions with int64 arguments in a hot loop.
local ty, mt, sel, re = "", "", 0, 0
for i = 1, 1000 do
  local v = (1 << 40) + i
  ty = type(v)
  mt = math.type(v)
  sel = select(2, 1, v)
  if rawequal(v, (1 << 40) + i) then re = re + 1 end
  assert(v)
end
p("ffunc", ty, mt, sel, re)
