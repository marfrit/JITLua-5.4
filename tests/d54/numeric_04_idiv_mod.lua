---! 5.4 floor division and modulo, every sign combination, for int32,
---! widened (|x| >= 2^32) and boxed (|x| >= 2^47) integers and for floats,
---! with constant and variable divisors, in hot loops so the JIT records
---! them: the recorder once emitted a float IR_MOD that the backend ran as
---! the int64 helper (mixed float/int64 '%'), and the float '%' used the
---! floor formula instead of fmod (-0.0 and large 2^i % 3 differed). Mode A
---! compares with PUC, mode B the JIT with the interpreter.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do local v = (select(i, ...)); t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "") end
  print(label, table.concat(t, " "))
end
local vals = {7, -7, 0, 1, -1, 2147483647, -2147483648, 1<<40, -(1<<40), 1<<62, -(1<<62), math.maxinteger, math.mininteger,
  7.0, -7.5, -0.0, 2^31, -(2^31), 2^60, -(2^60), 1e300}
local divs = {3, -3, 1, -1, 2, -2, 1<<40, -(1<<40), 1<<62, -(1<<62), 7, -7, 3.0, -3.0, -0.5, 2^40, -(2^40), 1e-300}
local function run(a, b) return a // b, a % b end
for _, a in ipairs(vals) do
  for _, b in ipairs(divs) do
    local q, r
    for i = 1, 60 do q, r = run(a, b) end
    p("var " .. tostring(a) .. " " .. tostring(b), q, r)
  end
end
local function cdiv(a)
  return a // 3, a % 3, a // -3, a % -3, a // -1, a % -1, a // 2, a % -2,
    a // -(1<<40), a % -(1<<40), a // -(1<<62), a % -(1<<62), a % -3.0, a // -0.5, a % 2^40
end
for _, a in ipairs(vals) do
  local t
  for i = 1, 60 do t = {cdiv(a)} end
  p("const " .. tostring(a), table.unpack(t, 1, 15))
end
local function cdd(b) return 7 // b, 7 % b, -7 // b, -7 % b, (1<<40) // b, (-(1<<40)) % b, (1<<62) % b, -7.5 % b, 2^60 % b end
for _, b in ipairs(divs) do
  local t
  for i = 1, 60 do t = {cdd(b)} end
  p("cdd " .. tostring(b), table.unpack(t, 1, 9))
end
-- loop-carried (narrowing, PHIs), int and float
local s1, s2, s3, s4 = 0, 0, 0, 0.0
for i = -200, 200 do
  s1 = s1 + (i // -3) + (i % -3)
  s2 = s2 + (i // 7) + (i % -7)
  s3 = s3 + ((i * (1<<35)) // -(1<<33)) + ((i * (1<<35)) % -(1<<33))
  s4 = s4 + ((i + 0.5) % -3) + ((i * 2^40) % 7.0)
end
p("loop", s1, s2, s3, s4)
-- PUC math.lua: 2^i % 3 alternates 1, 2 up to the largest finite power
local ok, i = true, 10
while 2^i < math.huge do if 2^i % 3 ~= i % 2 + 1 then ok = false end i = i + 1 end
local ok2 = true
i = 1
while (1 << i) ~= 0 do if (1 << i) % 3 ~= i % 2 + 1 and i < 63 then ok2 = false end i = i + 1 end
p("pow2mod3", ok, i, ok2)
-- zero divisors: integer errors, float nan/inf
p("zero", pcall(function() local z = 0 for i = 1, 60 do z = 7 // 0 end return z end))
p("zero2", pcall(function() local z = 0 for i = 1, 60 do z = (1<<40) % 0 end return z end))
local fz
for i = 1, 60 do fz = {7.0 // 0, -7 % 0.0, 0.0 % -0.0} end
p("fzero", fz[1], tostring(fz[2]) == tostring(0/0) and "nan" or fz[2], tostring(fz[3]) == tostring(0/0) and "nan" or fz[3])
