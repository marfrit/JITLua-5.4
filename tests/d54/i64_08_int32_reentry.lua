--! §3.4.4, §3.4.1: an integer is equal to an integer by value, whatever the
--! path it took. A compiled loop carries a result of 64-bit arithmetic as a
--! 64-bit value; the same instruction can give a result inside the int32
--! range on a later iteration (an accumulator passing through 0, a sum that
--! overflowed int32 only while the loop was hot), and a loop can be left
--! with such a value. Equality (==, ~=, rawequal, against a float too) and
--! the code after the loop must see the plain integer. Fixed output only.
local out = {}
local function rec(name, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local x = (select(i, ...))
    t[i] = tostring(x) .. ":" .. (math.type(x) or type(x))
  end
  out[#out+1] = name .. " " .. table.concat(t, " ")
end

local STEP = 1 << 33
local N = 300

-- 1. An accumulator outside int32 that is v for exactly one iteration (128).
local function eq_const(v)
  local p, z, f, at = (1 << 40) + v, 0, 0, 0
  for i = 1, N do
    p = p - STEP
    if p == 0 then z = z + 1; at = i end
    if p == 5 then f = f + 1; at = i end
  end
  return z, f, at
end
local function ne_const(v)
  local p, n = (1 << 40) + v, 0
  for i = 1, N do p = p - STEP; if p ~= 0 then n = n + 1 end end
  return n
end
local function eq_var(v, q)
  local p, a, b = (1 << 40) + v, 0, 0
  for i = 1, N do
    p = p - STEP
    if p == q then a = a + 1 end
    if q == p then b = b + 1 end
  end
  return a, b
end
local function raw(v)
  local p, a, b, c = (1 << 40) + v, 0, 0, 0
  local f = v + 0.0
  for i = 1, N do
    p = p - STEP
    if rawequal(p, v) then a = a + 1 end
    if rawequal(v, p) then b = b + 1 end
    if rawequal(p, f) then c = c + 1 end
  end
  return a, b, c
end
local function lib(v)
  local p, a, b = (1 << 40) + v, 0, 0
  for i = 1, N do
    p = p - STEP
    if math.max(p, v) == v then a = a + 1 end
    if math.abs(p) == (v < 0 and -v or v) then b = b + 1 end
  end
  return a, b
end
for _, v in ipairs{0, 5, -1} do
  rec("eq_const " .. v, eq_const(v))
  rec("ne_const " .. v, ne_const(v))
  rec("eq_var " .. v, eq_var(v, v))
  rec("raw " .. v, raw(v))
  rec("lib " .. v, lib(v))
end

-- 2. int32 operands: the result is outside int32 while the loop gets hot
-- and inside afterwards.
local BIG = 2147483647
local function ovf(n1)
  local a, b, c = {}, {}, {}
  for i = 1, N do
    if i <= n1 then a[i], b[i], c[i] = BIG, BIG, -2147483648
    else a[i], b[i], c[i] = i, -i, 7 end
  end
  local add, mul, unm = 0, 0, 0
  for i = 1, N do
    local x = a[i] + b[i]; if x == 0 then add = add + 1 end
    local y = a[i] * 65536; if y == i * 65536 then mul = mul + 1 end
    local z = -c[i]; if z == -7 then unm = unm + 1 end
  end
  return add, mul, unm
end
for _, n1 in ipairs{100, 57, 3} do rec("ovf " .. n1, ovf(n1)) end

-- 3. The inner loop is left with a value inside int32; the code after it
-- runs in a side trace of the loop.
local function after(n1)
  local eq7, eq0, key, inc = 0, 0, 0, 0
  local t = {[0] = 1, [7] = 2}
  for k = 1, 60 do
    local p = STEP * n1 + (k % 2) * 7
    for i = 1, n1 do p = p - STEP end
    if p == 7 then eq7 = eq7 + 1 end
    if p == 0 then eq0 = eq0 + 1 end
    key = key + (t[p] or 0)
    local q = p + 1
    if q == 8 then inc = inc + 1 end
  end
  return eq7, eq0, key, inc
end
-- The same exit, left with a small value two times out of three.
local function mixed(n1)
  local small, big, str = 0, 0, 0
  for k = 1, 90 do
    local p = STEP * (n1 + (k % 3 == 0 and 5 or 0))
    for i = 1, n1 do p = p - STEP end
    if p == 0 then small = small + 1 end
    if p == 5 << 33 then big = big + 1 end
    if tostring(p) == "0" then str = str + 1 end
  end
  return small, big, str
end
for _, n1 in ipairs{100, 60, 3} do
  rec("after " .. n1, after(n1))
  rec("mixed " .. n1, mixed(n1))
end

-- 4. A table that exists only in the trace (the allocation is sunk) holds the
-- value; it becomes real on the path that keeps it, which is a side trace.
local keep
local function sunk(n1, every)
  local raw, key, eq = 0, 0, 0
  local probe = {[0] = true, [7] = true}
  local p = STEP * n1 + 7
  for i = 1, 400 do
    p = p - STEP
    local t = {p, x = p}
    if i % every == 0 or p == 7 or p == 7 - STEP then
      keep = t
      if probe[t[1]] then key = key + 1 end
      if t.x == 7 then eq = eq + 1 end
      if rawequal(t[1], 7) then raw = raw + 1 end
    end
  end
  return raw, key, eq, keep[1], keep.x
end
for _, n1 in ipairs{200, 100, 3} do
  for _, every in ipairs{1000, 50, 7} do
    rec("sunk " .. n1 .. " " .. every, sunk(n1, every))
  end
end
print(table.concat(out, "\n"))
