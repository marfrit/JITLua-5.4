--! modes: A,B
-- Numeric for loops started inside compiled code (the FORI is recorded):
-- the limit conversion and the zero-trip decision must match PUC 5.4.9
-- lvm.c forprep/forlimit for every value the loop meets after it was
-- compiled, not only for the value seen while recording.
-- - integer loop, float limit: floor (ascending) or ceil (descending);
-- - a limit outside int32 (int64, boxed, float) makes a wide loop;
-- - a loop that is not entered (zero trip);
-- - float loop (float start or step) with an int64 or NaN limit: tonumber,
--   and PUC's forprep enters a NaN-limit float loop once.
-- Each shape runs 300 times with one kind of value (so it is compiled), then
-- with the others. Every loop has an iteration guard.

local function tp(x) return tostring(x) .. ":" .. (math.type(x) or type(x)) end

local function shape(name, f, warm, vals)
  local out = {}
  for k = 1, 300 do f(warm) end
  for _, v in ipairs(vals) do
    local n, first, last = f(v)
    out[#out + 1] = tostring(v) .. "=" .. n .. "," .. tp(first) .. "," .. tp(last)
  end
  print(name, table.concat(out, " "))
end

local function asc(lim)
  local n, first, last = 0, nil, nil
  for i = 1, lim do
    n = n + 1; first = first or i; last = i
    if n >= 12 then break end
  end
  return n, first, last
end
local function desc(lim)
  local n, first, last = 0, nil, nil
  for i = 10, lim, -1 do
    n = n + 1; first = first or i; last = i
    if n >= 12 then break end
  end
  return n, first, last
end
local function fstep(lim)
  local n, first, last = 0, nil, nil
  for i = 0, lim, 1.0 do
    n = n + 1; first = first or i; last = i
    if n >= 12 then break end
  end
  return n, first, last
end
local function finit(lim)
  local n, first, last = 0, nil, nil
  for i = 0.0, lim, 1 do
    n = n + 1; first = first or i; last = i
    if n >= 12 then break end
  end
  return n, first, last
end
local function fdesc(lim)
  local n, first, last = 0, nil, nil
  for i = 0, lim, -1.0 do
    n = n + 1; first = first or i; last = i
    if n >= 12 then break end
  end
  return n, first, last
end

local lims = {7.5, 7, 0, -3, 0.5, -0.5, -2.5, 2^31, 2^31 - 0.5, 2147483647,
              2147483648, 4294967296, 1 << 40, 1 << 62, math.maxinteger,
              math.mininteger, math.huge, -math.huge, 0/0, 1e10, "6", "6.5",
              "0x10", 3.0}
shape("asc float", asc, 7.5, lims)
shape("asc int", asc, 7, lims)
shape("asc zero", asc, 0, lims)
shape("desc float", desc, 2.5, lims)
shape("desc zero", desc, 20, lims)
shape("fstep i64", fstep, math.maxinteger, lims)
shape("fstep int", fstep, 5, lims)
shape("finit i64", finit, math.maxinteger, lims)
shape("finit nan", finit, 0/0, lims)
shape("fdesc i64", fdesc, math.mininteger, lims)

-- Half of an array length: an odd length gives a non-integral limit.
do
  local t = {}
  for i = 1, 101 do t[i] = i end
  local function half(t)
    local s = 0
    for i = 1, #t / 2 do s = s + t[i] end
    return s
  end
  local s = 0
  for k = 1, 300 do s = s + half(t) end
  t[102] = 102
  print("half", s, half(t))
end

-- A zero-trip inner loop in a hot outer loop, then a non-empty one.
do
  local function inner(n)
    local c = 0
    for o = 1, 300 do
      for i = 1, n do c = c + i end
    end
    return c
  end
  print("zerotrip", inner(0), inner(-5), inner(3), inner(0))
end
