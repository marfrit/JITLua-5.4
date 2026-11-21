--! §3.3.5: numeric 'for' follows PUC 5.4.9's forprep/forlimit/OP_FORLOOP
--! rules: the loop is an integer loop iff the initial value and the step are
--! integers (no string coercion for those two); then the limit is converted
--! with floor/ceil, clipped at the integer bounds or rejecting the loop; the
--! iteration count is precomputed in 64 bit. Otherwise a float loop converts
--! all three with tonumber. Step zero raises for both kinds. Differences from
--! today are listed in docs/notes/for-loop-54.md.
-- Every endless-loop candidate has an iteration guard, never a timeout.
local function strip(e)
  return (tostring(e):gsub("^.-:%d+: ", ""))
end
local function tp(x)
  return tostring(x) .. ":" .. (math.type(x) or type(x))
end
local function err(name, f)
  local ok, e = pcall(f)
  print(name, ok, strip(e))
end
-- A loop that is expected to raise at its start; the guard catches a loop
-- that wrongly runs instead (an endless loop otherwise).
local function zerr(name, init, lim, step)
  err(name, function()
    local n = 0
    for i = init, lim, step do
      n = n + 1
      if n > 100 then error("iteration guard: the loop ran instead of raising") end
    end
  end)
end
local function run(name, init, lim, step, guard)
  guard = guard or 100
  local n, first, last = 0, nil, nil
  local ok, e = pcall(function()
    for i = init, lim, step do
      n = n + 1
      if n == 1 then first = i end
      last = i
      if n >= guard then break end
    end
  end)
  print(name, ok, n, tp(first), tp(last), strip(e))
end

-- The kind decision: start and step only.
run("huge limit", 1, math.huge, 1, 3)          -- integer loop, clips to maxint
run("float limit 10.5", 1, 10.5, 1)            -- integer loop, floor -> 10
run("float limit 3.5", 1, 3.5, 1)              -- integer loop, floor -> 3
run("float limit 2.5 desc", 3, 0.5, -1)        -- ceil -> 1, three iterations
run("1 to 2^40", 1, 1 << 40, 1, 3)             -- integer loop
run("2^40 band", 1 << 40, (1 << 40) + 2, 1)    -- wide, three iterations
run("maxinteger band", math.maxinteger - 2, math.maxinteger, 1)
run("mininteger desc", math.mininteger + 2, math.mininteger, -1)
run("int32 edge asc", 2147483646, 2147483649, 1)
run("int32 edge desc", -2147483647, -2147483650, -1)
run("mininteger asc", math.mininteger, math.mininteger + 2, 1, 3)
run("wide desc", (1 << 40) + 2, 1 << 40, -1)
run("wide step band", 0, 1 << 35, 1 << 33)     -- five iterations
run("wide desc 2", 1 << 40, (1 << 40) - 8, -2) -- five iterations
run("step maxinteger", 1, math.huge, math.maxinteger)  -- one iteration
run("step mininteger desc", 1, -math.huge, math.mininteger)  -- two iterations
run("limit 2^63 clip", 1, 2^63, 1, 3)
run("limit -2^63", math.mininteger + 2, -(2^63), -1)
run("limit -inf skip", 1, -math.huge, 1)
run("limit nan skip", 1, 0/0, 1)
run("limit 2^63 desc skip", 1, 2^63, -1)       -- positive out-of-range limit skips a descending loop
run("float limit nan enter", 1.0, 0/0, 1)      -- NaN never compares: one body run
run("small wrapped idx", math.maxinteger - 1, math.maxinteger, 1)
run("min step wrap", math.mininteger, math.mininteger + 2, math.maxinteger)

-- Float loops: any string or float start/step.
run("string init", "1", 10, 1)
run("string all", "1", "10", "2")
run("float init", 1.0, 10, 1)
run("float step", -1, -10, -1.0)
run("float all", 1.0, 2.0, 0.5)
run("float integral step, int init", 1, 3.0, 1)  -- integer loop
run("string limit int init", 1, "10", 1)
run("string hex limit", 1, "0xffffffffffffffff", 1)  -- limit -1, skip
run("string maxint limit", 1, "9223372036854775807", 1, 3)
run("string 2^63 limit", 1, "9223372036854775808", 1, 3)  -- float, clips

-- Limit errors and 'for' step is zero, in PUC's order.
err("err limit table", function() for i = 1, {}, 1 do end end)
err("err limit float path", function() for i = 1.0, {}, 1 do end end)
err("err step float path", function() for i = 1.0, 2, "x" do end end)
err("err init float path", function() for i = {}, 2, 1 do end end)
zerr("err step zero int", 1, 2, 0)
zerr("err step zero wide init", 1 << 40, 2, 0)
zerr("err step zero float", 1.0, 2, 0.0)
zerr("err step zero before limit", 1, "x", 0)
err("err limit inf string", function() for i = 1, "inf", 1 do end end)

-- Break and goto out of a wide loop.
do
  local n, last = 0, nil
  for i = 1 << 40, (1 << 40) + 100 do
    n = n + 1; last = i
    if n == 6 then break end
  end
  print("wide break", n, tp(last))
end
do
  local n = 0
  for i = 1 << 40, (1 << 40) + 100 do
    n = n + 1
    if n == 3 then goto wideout end
  end
  ::wideout::
  print("wide goto", n)
end

-- A coroutine yields inside a wide loop.
do
  local co = coroutine.create(function()
    local t = {}
    for i = math.mininteger + 2, math.mininteger, -1 do
      t[#t + 1] = tp(i)
      coroutine.yield(i)
    end
    return t
  end)
  local got = {}
  for k = 1, 3 do
    local ok, v = coroutine.resume(co)
    got[#got + 1] = ok and tp(v) or ("err:" .. tostring(v))
  end
  print("wide coro", table.concat(got, " "))
end

-- Hot loops of each kind (more than 200 iterations), so a trace is recorded
-- and its exits are exercised under -jon.
local function hotint() local n = 0 for i = 1, 300 do n = n + 1 end return n end
local function hotflt() local n = 0 for i = 1.5, 300.5 do n = n + 1 end return n end
local function hotwide() local n, t = 0, nil
  for i = 1 << 40, (1 << 40) + 299 do n = n + 1; t = math.type(i) end
  return n, t
end
print("hot int", hotint(), hotint())
print("hot float", hotflt(), hotflt())
print("hot wide", hotwide(), hotwide())

-- A wide loop whose index leaves the int32 range inside the loop.
do
  local n, last = 0, nil
  for i = 2147483644, 2147483652 do n = n + 1; last = i end
  print("int32 leave", n, tp(last))
  assert(n == 9 and last == 2147483652)
end

-- A hot float loop (a trace may be patched to JFORI) whose limit then turns
-- NaN: PUC enters the body once, and the trace must not be entered.
do
  local function flim(lim)
    local n = 0
    for i = 1.0, lim do n = n + 1; if n > 10 then break end end
    return n
  end
  for k = 1, 300 do flim(5.0) end
  print("hot float nan limit", flim(5.0), flim(0/0), flim(0/0))
end
