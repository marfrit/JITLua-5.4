--! modes: A,B
-- A loop with an int32 start and step and a limit beyond int32
-- (`for j = 1, math.huge`) that sits inside a hot outer loop: a trace that
-- comes around the outer loop records the FORI of the inner one. That FORI
-- starts the loop in the clipped form (docs/notes/for-loop-54.md, step 4c)
-- and must be compiled, not end the trace; otherwise the code around a short
-- `for j = 1, math.huge do ... break end` stays in the interpreter.
--
-- The compiled check needs no timing: on the way around the outer loop a
-- trace either passes the FORI and links back to compiled code, or it gives
-- up there and falls back to the interpreter. PUC has no jit module and
-- `-joff` compiles nothing, so every arm prints "compiled" when the rule
-- holds. The values are PUC 5.4.9's (lvm.c forprep/forlimit/OP_FORLOOP).

local jit = rawget(_G, "jit")
local jutil
if jit and jit.status() then
  local ok, m = pcall(require, "jit.util")
  if ok then jutil = m end
end

local function links()  -- traces that end in compiled code / in the interpreter
  local good, bad = 0, 0
  for n = 1, 100000 do
    local ti = jutil.traceinfo(n)
    if not ti then break end
    if ti.linktype == "interpreter" then bad = bad + 1
    elseif ti.linktype == "loop" or ti.linktype == "root" then good = good + 1 end
  end
  return good, bad
end

local function tp(x) return tostring(x) .. ":" .. (math.type(x) or type(x)) end

local function check(name, f, ...)
  local g0, b0
  if jutil then g0, b0 = links() end
  local r = table.pack(f(...))
  local state = "compiled"
  if jit and jit.status() then
    if not jutil then state = "no jit.util"
    else
      local g1, b1 = links()
      if g1 - g0 < 2 or b1 ~= b0 then state = "NOT compiled" end
    end
  end
  for i = 1, r.n do r[i] = tp(r[i]) end
  print(name, state, table.concat(r, " "))
end

local C = 2147483647

-- One function per check: a check counts the traces of its own run.
local function mk(src) return assert(load("return " .. src))() end
local NEST = [[function(N, lim, st)
  local s, last = 0, nil
  for i = 1, N do
    local c = 0
    for j = 1, lim, st do
      s = s + j; last = j; c = c + 1
      if c >= (i % 5) + 2 then break end
    end
  end
  return s, last
end]]
local NESTDOWN = NEST:gsub("for j = 1,", "for j = -1,")

check("huge", mk(NEST), 3000, math.huge, 1)
check("1e10", mk(NEST), 3000, 1e10, 1)
check("maxinteger", mk(NEST), 3000, math.maxinteger, 1)
check("1<<40 step 3", mk(NEST), 3000, 1 << 40, 3)
check("-huge", mk(NESTDOWN), 3000, -math.huge, -1)
check("mininteger step -7", mk(NESTDOWN), 3000, math.mininteger, -7)
check("constant limit", mk[[function(N)
  local s = 0
  for i = 1, N do
    for j = 1, math.huge do s = s + j; if j > i % 4 then break end end
    for j = 10, 1e300, 2 do s = s + j; if j > i % 7 + 10 then break end end
  end
  return s
end]], 3000)

-- From here on only the values count.
local function show(name, ...)
  local r = table.pack(...)
  for i = 1, r.n do r[i] = tp(r[i]) end
  print(name, table.concat(r, " "))
end

-- The same FORI meets small limits, clipped limits, limits that skip the
-- loop, a NaN, a limit equal to the clip value, a start beyond the clip
-- value, and a start that makes the loop cross the int32 bound.
do
  local lims = {10, math.huge, 3, 1e10, -5, math.maxinteger, 0/0, C - 1,
		-math.huge, C, 2.5, 1 << 33, C + 0.5, -1e10, 7, math.mininteger}
  local starts = {1, 1, 1, 5, 1, C - 3, 1, C - 4, 1, C - 2, 1, C, 1, C - 1, -3}
  local s, cnt, lastj = 0, 0, nil
  for i = 1, 4000 do
    local lim = lims[i % #lims + 1]
    local a = starts[i % #starts + 1]
    local c = 0
    for j = a, lim do
      s = s + j % 13; c = c + 1; lastj = j
      if c >= 6 then break end
    end
    cnt = cnt + c
    if math.type(lastj) ~= "integer" then error("control variable is not an integer") end
  end
  show("mixed up", s, cnt, lastj)
  s, cnt, lastj = 0, 0, nil
  for i = 1, 4000 do
    local lim = lims[i % #lims + 1]
    local a = starts[i % #starts + 1]
    local c = 0
    for j = -a, lim, -1 - i % 3 do
      s = s + j % 13; c = c + 1; lastj = j
      if c >= 6 then break end
    end
    cnt = cnt + c
  end
  show("mixed down", s, cnt, lastj)
end

-- A clipped loop started by compiled code runs over the clip value.
do
  local s, cnt, last = 0, 0, nil
  for i = 1, 600 do
    for j = C - 3 - i % 3, 1e10, 1 + i % 2 do
      s = s + j % 7; cnt = cnt + 1; last = j
      if j >= C + 4 then break end
    end
  end
  show("cross", s, cnt, last)
  s, cnt, last = 0, 0, nil
  for i = 1, 600 do
    for j = -C + 3 + i % 3, -math.huge, -1 - i % 2 do
      s = s + j % 7; cnt = cnt + 1; last = j
      if j <= -C - 5 then break end
    end
  end
  show("cross down", s, cnt, last)
end

-- A clipped loop left early, then loops in the same slots whose real limit
-- is the clip value of the step: they end there.
do
  local n = 0
  for i = 1, 600 do
    for j = C - 10, 1e10 do if j == C - 8 then break end end
    for j = C - 5, C - 1 do n = n + 1 end
    for j = C - 9, C - 2, 2 do n = n + 1 end
    for j = -C + 4, -C, -1 do n = n + 1 end
    for j = C - 3, C + 3.0 do n = n + 1 end
  end
  show("stale", n)
end

-- Two clipped levels, an error out of the inner one, a coroutine.
do
  local s, e = 0, 0
  for i = 1, 500 do
    for j = 1, math.huge do
      for k = j, math.maxinteger, 2 do
	s = s + k
	if k > j + i % 4 then break end
      end
      if j > i % 3 then break end
    end
    local ok = pcall(function()
      for j = 1, 1e10 do if j > i % 5 then error("x") end s = s + 1 end
    end)
    if not ok then e = e + 1 end
  end
  show("levels", s, e)
  local co = coroutine.wrap(function()
    local t = 0
    for i = 1, 500 do
      for j = 1, math.huge do
	t = t + j
	if j % 3 == 0 then coroutine.yield(t) end
	if j > i % 6 then break end
      end
    end
    return -t
  end)
  local t, n = 0, 0
  while true do
    local v = co()
    if v < 0 then t = t - v break end
    n = n + 1
    for j = 1, 1e10 do t = t + 1; if j > n % 4 then break end end
  end
  show("coroutine", t, n)
end
