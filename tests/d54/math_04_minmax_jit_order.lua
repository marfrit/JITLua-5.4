--! §4.2 math.max/math.min keep the running best unless a later argument is
--! strictly greater/smaller (PUC lmathlib.c math_max/math_min with
--! lua_compare(..., LUA_OPLT)): max(nan, 1.0) is nan, max(1.0, nan) is 1.0,
--! min(0.0, -0.0) is 0.0, min(-0.0, 0.0) is -0.0. The recorder emitted
--! IR_MIN/IR_MAX(best, x), which both backends and the constant folder
--! evaluate to the second operand when the comparison is false, so a compiled
--! loop returned the opposite of the interpreter. Printed: the results of a
--! loop compiled for these values, with constants (folded) and variables.
local nan = 0 / 0
local function s(x)
  if x ~= x then return "nan" end
  if x == 0 then return 1 / x > 0 and "0.0" or "-0.0" end
  return tostring(x)
end
local args = {
  {nan, 1.0}, {1.0, nan}, {0.0, -0.0}, {-0.0, 0.0},
  {nan, nan}, {2.0, 2.0}, {-1.0, nan, 3.0}, {nan, -0.0, 0.0},
  {0.0, -0.0, -0.0}, {-0.0, 0.0, 0.0}, {1.0, 2.0, nan}, {3.0, nan, 1.0},
}
for _, a in ipairs(args) do
  local mx, mn
  for _ = 1, 100 do
    if #a == 2 then
      mx, mn = math.max(a[1], a[2]), math.min(a[1], a[2])
    else
      mx, mn = math.max(a[1], a[2], a[3]), math.min(a[1], a[2], a[3])
    end
  end
  local t = {}
  for i = 1, #a do t[i] = s(a[i]) end
  print(table.concat(t, ","), "max " .. s(mx), "min " .. s(mn))
end
-- Constant operands (folded at -O1 and up).
local r = {}
for i = 1, 100 do
  r[1] = math.max(nan, 1.0); r[2] = math.max(1.0, nan)
  r[3] = math.min(0.0, -0.0); r[4] = math.min(-0.0, 0.0)
  r[5] = math.max(0.0, -0.0); r[6] = math.max(-0.0, 0.0)
  r[7] = math.min(nan, 1.0); r[8] = math.min(1.0, nan)
end
for i = 1, 8 do r[i] = s(r[i]) end
print("const", table.concat(r, " "))
-- A loop compiled for ordinary values that then meets NaN and signed zeros.
local xs = {}
for i = 1, 90 do xs[i] = i + 0.5 end
xs[91] = nan; xs[92] = 1.0; xs[93] = -0.0; xs[94] = 0.0; xs[95] = nan
local out = {}
for i = 1, #xs - 1 do
  out[#out + 1] = s(math.max(xs[i], xs[i + 1])) .. "/" .. s(math.min(xs[i], xs[i + 1]))
end
print("late", table.concat(out, " ", 88))
local best = -math.huge
for i = 1, #xs do best = math.max(best, xs[i]) end
print("running max", s(best))
best = math.huge
for i = 1, #xs do best = math.min(xs[i], best) end
print("running min", s(best))
