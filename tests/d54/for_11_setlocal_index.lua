--! modes: A,B
-- debug.setlocal on the index of a running numeric for loop, the first of
-- its three "(for state)" variables. PUC 5.4.9 (lvm.c OP_FORLOOP) adds the
-- step to whatever integer that slot holds, so the loop continues from the
-- written index. That holds for a loop whose limit lies beyond int32 as
-- well (`for i = 1, math.huge`, `for i = 1, 1e10`), whatever form the VM
-- keeps its index in. Every loop leaves through its own guard: PUC counts
-- the iterations down and does not look at the limit again.

local C = 2147483647
local function tp(x) return tostring(x) .. ":" .. (math.type(x) or type(x)) end

-- The index slot of the innermost numeric loop of the caller.
local function idxslot()
  local k, found = 1, nil
  while true do
    local name = debug.getlocal(2, k)
    if not name then return found end
    if name == "(for state)" and debug.getlocal(2, k + 1) == "(for state)"
       and debug.getlocal(2, k + 2) == "(for state)" then
      found = k; k = k + 3
    else
      k = k + 1
    end
  end
end

local function run(name, a, lim, st, at, val, maxn)
  local n, seen = 0, {}
  for i = a, lim, st do
    n = n + 1
    seen[#seen + 1] = tp(i)
    if n == at then debug.setlocal(1, idxslot(), val) end
    if n >= maxn then break end
  end
  print(name, table.concat(seen, " "))
end

for rep = 1, 3 do
  run("small        ", 1, 100, 1, 3, 50, 7)
  run("huge         ", 1, math.huge, 1, 3, 50, 7)
  run("1e10         ", C - 50, 1e10, 1, 3, C - 10, 7)
  run("maxinteger   ", 5, math.maxinteger, 3, 2, -40, 7)
  run("to the bound ", C - 50, 1e10, 1, 3, C - 2, 9)
  run("over it      ", C - 50, 1e10, 1, 3, C + 10, 7)
  run("back under   ", C - 2, 1e10, 1, 5, 7, 9)
  run("wide start   ", C + 5, 1e11, 1, 3, 7, 7)
  run("wide step    ", 1, math.maxinteger, 1 << 33, 3, 7, 6)
  run("down         ", -1, -math.huge, -1, 3, -C + 2, 9)
  run("down 1e10    ", -C + 50, -1e10, -2, 3, 100, 7)
  run("mininteger   ", 0, math.mininteger, -1, 2, C, 6)
end

-- In a loop that is compiled before the write.
local function hot(a, lim, at, val, stop)
  local n, s, last = 0, 0, nil
  for i = a, lim do
    n = n + 1; s = s + i % 7; last = i
    if n == at then debug.setlocal(1, idxslot(), val) end
    if n >= stop then break end
  end
  return n .. " " .. tp(s) .. " " .. tp(last)
end
print("hot huge", hot(1, math.huge, 500, 10, 900))
print("hot 1e10", hot(C - 800, 1e10, 500, C - 100, 900))
print("hot wide", hot(C - 800, 1e10, 850, 3, 900))
