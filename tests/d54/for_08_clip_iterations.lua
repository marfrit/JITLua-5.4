--! modes: A,B
-- Integer for loops with an int32 initial value and step and a limit beyond
-- int32 run on the int32 path up to the last index whose int32 add cannot
-- overflow and continue as wide loops from there. The iterations must be
-- PUC 5.4.9's (lvm.c forprep/forlimit/OP_FORLOOP): an integer control
-- variable, the precomputed count including an end beyond int32, no endless
-- loop. Checked across the int32 boundary in both directions, at and next to
-- the switch point, with break, goto, return, yield, nested loops, a real
-- limit equal to the switch point (also after a loop left early in the same
-- slots), the debug library writing the step, and with the loops compiled
-- before they cross (each shape first runs hot without crossing).
-- Every loop has an iteration guard.

-- Side traces start after the first taken exit, so the exits of the compiled
-- loops are recorded as well (PUC has no jit module).
if jit and jit.opt then jit.opt.start("hotexit=1") end

local MAX, MIN = 2147483647, -2147483648
local function tp(x) return tostring(x) .. ":" .. (math.type(x) or type(x)) end

-- Run f(a, lim, st, guard) and report count, first, last, sum.
local function run(f, a, lim, st, guard)
  local n, first, last, sum = f(a, lim, st, guard)
  return n .. "," .. tp(first) .. "," .. tp(last) .. "," .. tp(sum)
end

local function loop(a, lim, st, guard)
  local n, first, last, sum = 0, nil, nil, 0
  for i = a, lim, st do
    n = n + 1; first = first or i; last = i; sum = sum + i
    if n >= guard then break end
  end
  return n, first, last, sum
end

-- Warm up: the same shape with a start far from the int32 bound, so the loop
-- is compiled (under -jon) in its int32 phase, then the crossing calls.
local function shape(name, f, warm, cases)
  for k = 1, 300 do f(warm[1], warm[2], warm[3], 40) end
  local out = {}
  for _, c in ipairs(cases) do
    out[#out + 1] = run(f, c[1], c[2], c[3], c[4] or 2000)
  end
  print(name, table.concat(out, " "))
end

-- 1. Ascending, crossing INT32_MAX: start 300 steps below the switch point.
for _, st in ipairs({1, 7, 1000, 65536, 2147483647}) do
  local a = MAX - st - 300 * st
  if a < MIN then a = 0 end
  shape("asc st=" .. st, loop, {1, math.huge, st}, {
    {a, math.huge, st, 700},
    {a, 1e10, st, 700},
    {a, math.maxinteger, st, 700},
    {a, MAX + 5, st},              -- ends just past int32
    {a, MAX + 0.5, st},            -- float limit, floor
    {a, "3000000000", st, 700},    -- string limit
    {a, 2^31, st},
    {a, (1 << 32) + 3, st, 700},
  })
end

-- 2. Descending, crossing INT32_MIN.
local function dloop(a, lim, st, guard) return loop(a, lim, st, guard) end
for _, st in ipairs({-1, -3, -1000, -2147483647, MIN}) do
  local a = MIN - st - 300 * st
  if a > MAX then a = 0 end
  shape("desc st=" .. st, dloop, {-1, -math.huge, st}, {
    {a, -math.huge, st, 700},
    {a, -1e10, st, 700},
    {a, math.mininteger, st, 700},
    {a, MIN - 5, st},
    {a, MIN - 0.5, st},
    {a, "-3000000000", st, 700},
    {a, -2^31 - 1, st},
  })
end

-- 3. Starts at, below and above the switch point C = INT32_MAX - step.
local function sloop(a, lim, st, guard) return loop(a, lim, st, guard) end
shape("switch point", sloop, {1, math.huge, 5}, {
  {MAX - 5, math.huge, 5, 5},       -- a == C
  {MAX - 6, math.huge, 5, 5},       -- a == C - 1
  {MAX - 4, math.huge, 5, 5},       -- a == C + 1: wide from the start
  {MAX, math.huge, 5, 5},
  {MAX - 5, MAX, 5, 5},             -- real limit INT32_MAX
  {MAX - 5, MAX - 5, 5, 5},         -- real limit == C
  {MAX - 5, MAX - 6, 5, 5},         -- skipped
  {0, math.huge, MAX, 5},           -- C == 0
  {1, math.huge, MAX, 5},           -- wide from the start
  {0, -math.huge, MIN, 5},          -- C == 0, descending
  {MIN + 7, -math.huge, -7, 5},     -- a == C, descending
})

-- 4. A real limit equal to C, also right after a clipped loop left early in
-- the same slots (that loop's real limit must not be picked up), from the
-- interpreter, from a compiled loop and from a loop started inside compiled
-- code (an inner loop).
local function twoloops(a, lim, st, guard)
  local n1, n, first, last, sum = 0, 0, nil, nil, 0
  for i = a, math.huge, st do   -- the same slots as the next loop
    n1 = n1 + 1
    if n1 >= 3 then break end
  end
  for j = a, lim, st do
    n = n + 1; first = first or j; last = j; sum = sum + j
    if n >= guard then break end
  end
  return n, first, last, sum + n1
end
shape("real limit C", twoloops, {1, 2147483646 - 200000, 1}, {
  {MAX - 400, MAX - 1, 1},          -- lim == C for step 1
  {MAX - 400, MAX, 1},
  {MAX - 400, MAX - 2, 1},
  {MAX - 4000, MAX - 3, 3},         -- lim == C for step 3
  {MIN + 400, MIN + 1, -1},         -- lim == C for step -1
  {MAX - 400, math.huge, 1, 700},
})
local function climit(a, lim, guard)
  local n, last = 0, nil
  for i = a, lim do
    n = n + 1; last = i
    if n >= guard then break end
  end
  return n, last
end
local function nestedc(a, lim, guard)
  local n, last = 0, nil
  for k = 1, 3 do
    for i = a, lim do
      n = n + 1; last = i
      if n >= guard * k then break end
    end
  end
  return n, last
end
do
  for k = 1, 300 do climit(1, 50, 100); nestedc(1, 50, 100) end
  -- Step 1: C = 2147483646 as a real limit and as the clipped one,
  -- alternating, through the compiled loops.
  local out, out2 = {}, {}
  for k = 1, 8 do
    local lim = (k % 2 == 0) and math.huge or (k % 4 == 1) and MAX - 1 or MAX
    local n, last = climit(MAX - 300, lim, 400)
    out[#out + 1] = n .. "," .. tp(last)
    n, last = nestedc(MAX - 300, lim, 400)
    out2[#out2 + 1] = n .. "," .. tp(last)
  end
  print("climit", table.concat(out, " "))
  print("nestedc", table.concat(out2, " "))
end

-- 5. break, goto, return out of a loop that crossed, then the same slots
-- reused by a small loop.
local function exits(a)
  local r = {}
  for i = a, math.huge do
    if i > MAX + 2 then r[#r + 1] = "break@" .. tp(i); break end
  end
  for i = a, math.huge do
    if i > MAX + 3 then r[#r + 1] = "goto@" .. tp(i); goto done end
  end
  ::done::
  local function ret()
    for i = a, math.huge do
      if i > MAX + 4 then return i end
    end
  end
  r[#r + 1] = "return@" .. tp(ret())
  local n = 0
  for i = MAX - 3, MAX do n = n + 1 end
  r[#r + 1] = "small=" .. n
  return table.concat(r, " ")
end
for k = 1, 300 do exits(MAX - 300) end
print("exits", exits(MAX - 300))

-- 6. A coroutine yielding inside a loop that crosses.
do
  local gen = coroutine.wrap(function()
    for i = MAX - 300, math.huge do coroutine.yield(i) end
  end)
  local n, last, types = 0, nil, {}
  for k = 1, 700 do
    last = gen(); n = n + 1
    types[math.type(last)] = true
  end
  print("yield", n, tp(last), types.integer, types.float)
end

-- 7. Nested: a crossing inner loop in a small outer loop, and a crossing
-- inner loop in a crossing outer loop.
do
  local s, cnt = 0, 0
  for k = 1, 5 do
    for i = MAX - 300, math.huge do
      cnt = cnt + 1; s = s + i
      if i >= MAX + 10 then break end
    end
  end
  print("nested", cnt, tp(s))
  local oc, ic = 0, 0
  for o = MAX - 100, math.huge do
    oc = oc + 1
    for i = MIN + 50, -math.huge, -1 do
      ic = ic + 1
      if i <= MIN - 5 then break end
    end
    if o >= MAX + 5 then break end
  end
  print("nested2", oc, ic)
end

-- 8. The debug library writes the step slot of a running loop with the value
-- it already holds, before the loop crosses: the iterations do not change.
local function forslots(lv)
  lv = lv + 1
  local found, i = {}, 1
  while true do
    local n = debug.getlocal(lv, i)
    if not n then break end
    if n == "(for state)" then found[#found + 1] = i end
    i = i + 1
  end
  local k = #found
  return found[k - 2], found[k - 1], found[k]
end
local function rewrite_step(lv)
  local _, _, c = forslots(lv + 1)
  local _, v = debug.getlocal(lv + 1, c)
  debug.setlocal(lv + 1, c, v)
end
local function dbg(a, lim, st, guard)
  local n, first, last, sum = 0, nil, nil, 0
  for i = a, lim, st do
    n = n + 1; first = first or i; last = i; sum = sum + i
    if n == 5 then rewrite_step(1) end
    if n >= guard then break end
  end
  return n, first, last, sum
end
print("setlocal step", run(dbg, MAX - 50, math.huge, 1, 200),
      run(dbg, MIN + 50, -math.huge, -1, 200),
      run(dbg, MAX - 50, MAX + 3, 1, 200))

-- 9. Many short clipped loops at the same slots (the clip list must not
-- grow without bound or mix them up): every one ends where its break says.
do
  local total = 0
  local function f(k)
    for i = 1, math.huge do
      if i >= k then total = total + i; break end
    end
  end
  for k = 1, 3000 do f(k % 50 + 1) end
  print("many", total)
end

-- 10. Loops whose only int32 iteration is the one at the switch point, run
-- hot inside an outer loop: the FORL that gets hot leaves the int32 path.
do
  local n, last = 0, nil
  for k = 1, 300 do
    for j = MAX - 1, MAX + 2 do n = n + 1; last = j end
    for j = MIN + 1, MIN - 2, -1 do n = n + 1; last = j end
  end
  print("one int32 iteration", n, tp(last))
end
