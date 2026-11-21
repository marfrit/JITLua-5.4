--! modes: A,B
-- Numeric for loops whose initial value and step fit int32 but whose limit
-- lies beyond int32 (`for i = 1, math.huge`, `1, 1e10`, `1, math.maxinteger`
-- and the descending mirrors) are integer loops in Lua 5.4 (PUC 5.4.9 lvm.c
-- forprep/forlimit). Such a loop usually ends with a break long before its
-- index leaves int32; it must run on the int32 path and be compiled like any
-- small integer loop, not through a C call per iteration.
--
-- The compiled check needs no timing: a FORL that got a trace is patched to
-- JFORL, which jit.util.funcbc shows. PUC has no jit module and `-joff`
-- compiles nothing, so every arm prints "compiled" when the rule holds; only
-- `-jon` can print "NOT compiled". The values are compared in every mode.

local jit = rawget(_G, "jit")
local jutil, JFORL
if jit and jit.status() then
  local ok, m = pcall(require, "jit.util")
  if ok then
    jutil = m
    -- The opcodes from a loop with an empty body that never runs hot: FORI
    -- jumps one instruction forward, the FORL right after it one back, and
    -- lj_bc.h orders them FORI JFORI FORL IFORL JFORL.
    local function probe() for i = 1, 2 do end end
    local prev
    for pc = 1, 100 do
      local ins = jutil.funcbc(probe, pc)
      if not ins then break end
      if prev and (prev >> 16) & 0xffff == 0x8001 and
         (ins >> 16) & 0xffff == 0x7fff and ins & 0xff == (prev & 0xff) + 2 then
        JFORL = (ins & 0xff) + 2
      end
      prev = ins
    end
  end
end

-- Does f (not its inner functions) hold a FORL that got a trace?
local function hasjforl(f)
  for pc = 1, 100000 do
    local ins = jutil.funcbc(f, pc)
    if not ins then return false end
    if ins & 0xff == JFORL then return true end
  end
  return false
end

local function tp(x) return tostring(x) .. ":" .. (math.type(x) or type(x)) end

local function check(name, f, ...)
  local s, last = f(...)
  local state = "compiled"
  if jit and jit.status() then
    if not (jutil and JFORL) then state = "no jit.util"
    elseif not hasjforl(f) then state = "NOT compiled" end
  end
  print(name, state, tp(s), tp(last))
end

local N = 2000

check("huge", function(n)
  local s, last = 0, nil
  for i = 1, math.huge do
    s = s + i; last = i
    if i >= n then break end
  end
  return s, last
end, N)

check("1e10", function(n)
  local s, last = 0, nil
  for i = 1, 1e10 do
    s = s + i; last = i
    if i >= n then break end
  end
  return s, last
end, N)

check("maxinteger", function(n)
  local s, last = 0, nil
  for i = 1, math.maxinteger do
    s = s + i; last = i
    if i >= n then break end
  end
  return s, last
end, N)

check("int64 limit, step 3", function(n)
  local s, last = 0, nil
  for i = 5, 1 << 40, 3 do
    s = s + i; last = i
    if i >= 3 * n then break end
  end
  return s, last
end, N)

check("-huge, step -1", function(n)
  local s, last = 0, nil
  for i = -1, -math.huge, -1 do
    s = s + i; last = i
    if i <= -n then break end
  end
  return s, last
end, N)

check("mininteger, step -2", function(n)
  local s, last = 0, nil
  for i = 0, math.mininteger, -2 do
    s = s + i; last = i
    if i <= -2 * n then break end
  end
  return s, last
end, N)

check("limit in a variable", function(lim, n)
  local s, last = 0, nil
  for i = 1, lim do
    s = s + i; last = i
    if i >= n then break end
  end
  return s, last
end, math.huge, N)

check("while-true idiom, goto out", function(n)
  local s, last = 0, nil
  for i = 1, math.huge do
    s = s + i; last = i
    if i >= n then goto out end
  end
  ::out::
  return s, last
end, N)

check("inner loop", function(n)
  local s, last = 0, nil
  for k = 1, 4 do
    for i = 1, math.huge do
      s = s + i; last = i
      if i >= n then break end
    end
  end
  return s, last
end, N)
