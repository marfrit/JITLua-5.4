--! modes: A,B
-- The hidden "(for state)" slots of a numeric for loop, read and written
-- through the debug library (PUC 5.4.9 lvm.c forprep/OP_FORLOOP keep plain
-- numbers there: index, count or limit, step).
--
-- What PUC and this VM agree on, and what this file compares:
-- - the three slots hold numbers in every loop kind (a wide integer loop used
--   to keep a private state object there, which leaked as a userdata);
-- - the step slot holds the step with its type;
-- - copying all three slots of a running loop into another running loop makes
--   the second one continue with the first one's remaining iterations (PUC
--   copies index/count/step, this VM index/limit/step: the same iterations);
--   the body that runs is always the second loop's own.
-- The exact values of the index and count slots differ by design
-- (docs/DIFFERENCES.md) and are not printed.
-- Every loop that could run away has an iteration guard.

local function tp(x) return tostring(x) .. ":" .. (math.type(x) or type(x)) end

-- Indices of the innermost loop's three "(for state)" slots at level lv.
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

local function slottypes(lv)
  local a, b, c = forslots(lv + 1)
  local _, va = debug.getlocal(lv + 1, a)
  local _, vb = debug.getlocal(lv + 1, b)
  local _, vc = debug.getlocal(lv + 1, c)
  return type(va) .. "," .. type(vb) .. "," .. tp(vc)
end

-- 1. Slot types in each loop kind, on the first and a later iteration.
local function kinds()
  local out = {}
  for i = 1, 2 do out[#out + 1] = "small " .. slottypes(1) end
  for i = 1.0, 2.0 do out[#out + 1] = "float " .. slottypes(1) end
  for i = 1 << 40, (1 << 40) + 1 do out[#out + 1] = "wide " .. slottypes(1) end
  for i = 1, math.huge do
    out[#out + 1] = "huge " .. slottypes(1)
    if i >= 2 then break end
  end
  for i = math.maxinteger - 1, math.maxinteger do
    out[#out + 1] = "maxint " .. slottypes(1)
  end
  for i = -1, math.mininteger, -(1 << 62) do
    out[#out + 1] = "bigstep " .. slottypes(1)
  end
  for i = 2147483646, 2147483649 do out[#out + 1] = "edge " .. slottypes(1) end
  return table.concat(out, " | ")
end
print(kinds())

-- 2. Copy the three slots of a running loop (in another function) into a
-- running loop; the receiving loop runs the giver's remaining iterations.
local function grab(lv)
  local a, b, c = forslots(lv + 1)
  local _, va = debug.getlocal(lv + 1, a)
  local _, vb = debug.getlocal(lv + 1, b)
  local _, vc = debug.getlocal(lv + 1, c)
  return {va, vb, vc}
end
local function put(lv, s)
  local a, b, c = forslots(lv + 1)
  debug.setlocal(lv + 1, a, s[1])
  debug.setlocal(lv + 1, b, s[2])
  debug.setlocal(lv + 1, c, s[3])
end

local function giver(init, lim, step, at)
  local n = 0
  for i = init, lim, step do
    n = n + 1
    if n == at then return grab(1) end
  end
end

local function receiver(name, s, init, lim, step)
  local seen, n = {}, 0
  for j = init, lim, step do
    n = n + 1
    seen[#seen + 1] = tp(j)
    if n == 2 then put(1, s) end
    if n > 12 then seen[#seen + 1] = "guard"; break end
  end
  print(name, n, table.concat(seen, " "))
end

-- wide -> wide
receiver("wide>wide", giver(1 << 40, (1 << 40) + 5, 1, 2), 1 << 41, (1 << 41) + 9)
-- wide (huge limit) -> small
receiver("huge>small", giver(7, math.huge, 3, 2), 1, 10)
-- small -> wide
receiver("small>wide", giver(1, 6, 1, 3), 1 << 41, (1 << 41) + 9)
-- float -> wide
receiver("float>wide", giver(0.5, 3.5, 1, 1), 1 << 41, (1 << 41) + 9)
-- wide descending -> wide ascending
receiver("desc>asc", giver(math.mininteger + 4, math.mininteger, -1, 1),
         1 << 41, (1 << 41) + 9)
-- wide (in int32 range, huge limit) -> float
receiver("huge>float", giver(-3, math.huge, 1, 1), 0.25, 4.25)

-- 3. The same copy into a loop of the same function in a recursive call: the
-- outer activation's state stays its own.
do
  local saved
  local log = {}
  local function rec(depth)
    local n = 0
    for i = (1 << 40) + depth * 100, (1 << 40) + depth * 100 + 4 do
      n = n + 1
      if depth == 0 and n == 2 then saved = grab(1); rec(1) end
      if depth == 1 and n == 1 then put(1, saved) end
      log[#log + 1] = depth .. ":" .. (i - (1 << 40))
      if n > 10 then break end
    end
  end
  rec(0)
  print("recursive", table.concat(log, " "))
end

-- 4. Hot copies under the JIT: the receiving loop is compiled before it
-- meets a copied state.
do
  local function hot(s)
    local n, sum = 0, 0
    for j = 1, 400 do
      n = n + 1
      if s and n == 300 then put(1, s) end
      sum = sum + (j & 0xffff)
      if n > 1000 then break end
    end
    return n, sum
  end
  for k = 1, 3 do hot(nil) end
  print("hot", hot(nil))
  print("hot<wide", hot(giver(1 << 40, (1 << 40) + 9, 1, 3)))
  print("hot<huge", hot(giver(5, math.huge, 2, 1)))
  print("hot<float", hot(giver(0.5, 9.5, 1, 1)))
end
