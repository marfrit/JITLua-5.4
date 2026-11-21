--! modes: B
-- Forged "(for state)" slots: debug.setlocal writes a value of another kind
-- into the hidden index, limit or step slot of a running numeric for loop.
--
-- PUC 5.4.9 (lvm.c OP_FORLOOP, floatforloop) reads those slots without a
-- type check and reinterprets the raw bits of its TValue union, so there is
-- no PUC result to compare with (no mode A; docs/DIFFERENCES.md). This VM
-- must never crash or read through a forged value: the loop continues with
-- what the slots now say (an integer loop if the step slot holds an integer,
-- a float loop if it holds a float) or raises a clean error. The JIT must
-- agree with the interpreter, also for loops that were compiled before the
-- forged value arrives.
-- Every loop has an iteration guard.

local function tp(x) return tostring(x) .. ":" .. (math.type(x) or type(x)) end
local function strip(e) return (tostring(e):gsub("^.-:%d+: ", "")) end

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
local function forge(lv, which, v)
  local s = {forslots(lv + 1)}
  debug.setlocal(lv + 1, s[which], v)
end

local function run(name, init, lim, step, which, v, at, guard)
  at, guard = at or 1, guard or 12
  local seen, n = {}, 0
  local ok, e = pcall(function()
    for i = init, lim, step do
      n = n + 1
      seen[#seen + 1] = tp(i)
      if n == at then forge(1, which, v) end
      if n >= guard then seen[#seen + 1] = "guard"; break end
    end
  end)
  print(name, ok, ok and "" or strip(e), n, table.concat(seen, " "))
end

local IDX, LIM, STEP = 1, 2, 3
local function isint32(v)
  return math.type(v) == "integer" and v >= -2147483648 and v <= 2147483647
end
local values = {1, 2, 0, -1, 1 << 40, 1 << 60, math.mininteger, 2.5, 3.0,
                0/0, math.huge, "1", "x", {}, true, print}

-- Float loop: every value into every slot (integer step: an integer loop).
for _, v in ipairs(values) do
  for w = IDX, STEP do
    run("float " .. w .. " " .. tp(v), 1.0, 3.0, 1.0, w, v)
  end
end
-- Wide integer loops, the index outside int32 and inside it (huge limit).
for _, v in ipairs(values) do
  for w = IDX, STEP do
    -- An int32 index next to a wide limit or step is not forged: the int32
    -- fast path would read the low word of the other slots (memory-safe,
    -- but the result depends on the box address).
    if not (w == IDX and isint32(v)) then
      run("wide " .. w .. " " .. tp(v), 1 << 40, (1 << 40) + 3, 1, w, v)
      run("huge " .. w .. " " .. tp(v), 1, math.huge, 1, w, v)
      run("desc " .. w .. " " .. tp(v), math.mininteger + 3, math.mininteger, -1, w, v)
    end
  end
end
-- Small integer loop: a forged index outside int32 or of another type, and
-- an int32 step or limit (a boxed one would be read by its low word).
for _, v in ipairs{1 << 40, 1 << 60, math.mininteger, 2.5, 3.0, "x", {}} do
  run("small idx " .. tp(v), 1, 3, 1, IDX, v)
end
for _, v in ipairs{3, -2, 0, 2} do
  run("small step " .. tp(v), 1, 3, 1, STEP, v)
  run("small limit " .. tp(v), 1, 3, 1, LIM, v)
end

-- Hot loops: compiled before the forged value arrives at iteration 300.
local function hot(init, lim, step, which, v)
  local n, last = 0, nil
  local ok, e = pcall(function()
    for i = init, lim, step do
      n = n + 1
      last = i
      if n == 300 and which ~= 0 then forge(1, which, v) end
      if n >= 320 then break end
    end
  end)
  return tostring(ok) .. " " .. (ok and "" or strip(e)) .. " " .. n .. " " .. tp(last)
end
for _, v in ipairs{2, 1 << 40, 2.5, 0, "x"} do
  for w = IDX, STEP do
    for k = 1, 3 do hot(1.0, 400.0, 1.0, 0, nil) end
    print("hot float", w, tp(v), hot(1.0, 400.0, 1.0, w, v))
    for k = 1, 3 do hot(1, 400, 1, 0, nil) end
    -- A compiled small loop keeps its constant limit and step in the trace
    -- (stock LuaJIT does too); only a forged index of another kind is
    -- compared there.
    if w == IDX and not isint32(v) then
      print("hot small", w, tp(v), hot(1, 400, 1, w, v))
    end
    if not (w == IDX and isint32(v)) then  -- see the wide loops above
      print("hot huge", w, tp(v), hot(1, math.huge, 1, w, v))
    end
  end
end
print("done")
