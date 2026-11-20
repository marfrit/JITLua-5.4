--! §3.3.5: a numeric for loop whose start, limit or step is an integer
--! outside the int32 range, in code that gets compiled. The number of
--! iterations and the values must be the same with and without the JIT.
--! Against PUC 5.4.9 this file differs (tests/known-bad.tsv): the loop
--! variable of such a loop is a float here, and from 2^53 on the loop does
--! not count correctly. The counts below stop at 20 for that reason.
local out = {}
local function rec(name, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local x = (select(i, ...))
    t[i] = tostring(x) .. ":" .. (math.type(x) or type(x))
  end
  out[#out+1] = name .. " " .. table.concat(t, " ")
end

-- Constant bounds; the for loop is entered from a loop that gets hot.
local function consts()
  local a, b, c, d, last = 0, 0, 0, 0
  for i = 1, 200 do
    for j = 1 << 40, (1 << 40) + 2 do a = a + 1; last = j end
    for j = 2147483646, 2147483649 do b = b + 1 end
    for j = -2147483647, -2147483650, -1 do c = c + 1 end
    for j = 0, 1 << 35, 1 << 33 do d = d + 1 end
  end
  return a, b, c, d, last
end
-- Bounds from variables and from arithmetic.
local function vars(lo, n)
  local a, s = 0, 0
  for i = 1, 200 do
    local hi = lo + n
    for j = lo, hi do a = a + 1; if j % 2 == 0 then s = s + 1 end end
  end
  return a, s
end
-- The loop itself gets hot.
local function hot(lo)
  local a = 0
  for j = lo, lo + 999 do a = a + 1 end
  return a
end
-- A limit that is outside int32 while the trace is recorded and inside later.
local function drift()
  local a, p = 0, (1 << 33) * 150 + 3
  for i = 1, 300 do
    p = p - (1 << 33)
    if p >= 0 and p < 1 << 34 then
      for j = p - 2, p do a = a + 1 end
    end
  end
  return a
end
-- A loop that is left with a small value, which is then a limit.
local function after()
  local a, ty = 0, nil
  for k = 1, 60 do
    local p = (1 << 33) * 100 + 3
    for i = 1, 100 do p = p - (1 << 33) end
    for j = 1, p do a = a + 1; ty = math.type(j) end
  end
  return a, ty
end
-- What differs from PUC: the type of the loop variable, and the count from
-- 2^53 on.
local function types()
  local t1, t2, n1, n2, n3
  for j = 2147483646, 2147483649 do t1 = math.type(j) end
  for j = 1, math.maxinteger do t2 = math.type(j); break end
  n1 = 0; for j = (1 << 53) + 1, (1 << 53) + 5 do n1 = n1 + 1; if n1 >= 20 then break end end
  n2 = 0; for j = math.maxinteger - 2, math.maxinteger do n2 = n2 + 1; if n2 >= 20 then break end end
  n3 = 0; for j = math.mininteger, math.mininteger + 2 do n3 = n3 + 1; if n3 >= 20 then break end end
  return t1, t2, n1, n2, n3
end

rec("consts", consts())
rec("vars", vars(1 << 40, 3))
rec("vars", vars(2147483645, 5))
rec("vars", vars(-(1 << 40), 3))
rec("hot", hot(1 << 40), hot(2147483000), hot(-2147484000))
rec("drift", drift())
rec("after", after())
for i = 1, 100 do types() end
rec("types", types())
print(table.concat(out, "\n"))
