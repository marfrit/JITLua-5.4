--! modes: A,B
-- A numeric for loop whose header slots are not written by the trace that
-- records its FORI: the step (or all three values) comes straight from a
-- call of a C function that is not compiled, so the trace is cut there and
-- a new one starts right before the FORI, which loads the slots from the
-- stack. The loop is short and gets unrolled; later its trip count changes,
-- the exit at its FORL gets hot and a side trace starts there. The exit of
-- an integer FORL restores the index minus the step, so the side trace needs
-- the step although the parent never changed that slot. Every shape must
-- count like PUC 5.4.9 (lvm.c forprep/OP_FORLOOP). The trip count is
-- computed without a branch: a branch would move the change to an earlier
-- exit and the FORL exit would never get hot.

if jit and jit.opt then jit.opt.start("hotexit=1") end

local ulen, unpk, char = utf8.len, string.unpack, string.char

-- The step comes from the C call.
local function up(N, sw, lo, hi)
  local acc = 0
  for i = 1, N do
    local n = lo + (i // sw) * hi
    for j = 1, n, ulen("a") do acc = acc + j end
  end
  return acc
end

local function down(N, sw, lo, hi)
  local acc = 0
  for i = 1, N do
    local n = lo + (i // sw) * hi
    for j = n, 1, -(ulen("a")) do acc = acc + j * 3 end
  end
  return acc
end

-- Start, limit and step all come from C calls: none of the three slots is
-- in the snapshots of the trace.
local function all3(N, sw, lo, hi)
  local acc = 0
  for i = 1, N do
    local n = lo + (i // sw) * hi
    for j = (unpk("b", "\1")), (unpk("b", char(n))), ulen("a") do
      acc = acc + j
    end
  end
  return acc
end

-- The trip count keeps changing after the switch.
local function vary(N, sw, lo, hi)
  local acc = 0
  for i = 1, N do
    local n = lo + (i // sw) * (hi + i % 3)
    for j = 1, n, ulen("a") do
      acc = acc + j
      if j == 4 then acc = acc + 1 end
    end
  end
  return acc
end

-- A step of two, and the loop in a function of its own.
local function inner(n, acc)
  for j = 1, n, ulen("ab") do acc = acc + j end
  return acc
end
local function called(N, sw, lo, hi)
  local acc = 0
  for i = 1, N do acc = inner(lo + (i // sw) * hi, acc) end
  return acc
end

-- Inside a coroutine that yields now and then.
local function coro(N, sw, lo, hi)
  local co = coroutine.wrap(function()
    local acc = 0
    for i = 1, N do
      local n = lo + (i // sw) * hi
      for j = 1, n, ulen("a") do acc = acc + j end
      if i % 97 == 0 then coroutine.yield(acc) end
    end
    return -acc
  end)
  local t = 0
  while true do
    local v = co()
    if v < 0 then return t - v end
    t = t + v % 1000
  end
end

for _, f in ipairs{up, down, all3, vary, called, coro} do
  print(f(3000, 1500, 2, 3), f(3000, 1600, 1, 3), f(3000, 2000, 2, 1),
	f(3000, 1000, 1, 1), f(3000, 2500, 3, 6), f(400, 150, 2, 2))
end
