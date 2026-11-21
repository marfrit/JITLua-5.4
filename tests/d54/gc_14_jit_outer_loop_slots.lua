--! A GC check at the head of a compiled inner loop must keep the locals of the
--! enclosing loop body. An inner `break` that the parser threads straight to
--! the outer loop's back edge, or a `goto` to the LOOP of an enclosing
--! `repeat`, is a backward jump that leaves the inner loop: it is not the
--! inner loop's back edge, and the live range below it is the outer body's.
--! Every inner loop allocates a table that escapes (so the trace keeps its
--! GC check) and reads the outer local `a` on every pass. PUC, -joff and -jon
--! (every opt level) must agree on the counts.
local function p(...) print(...) end

-- inner `break` threaded to the enclosing `while true` loop
local function nested_break(N, M)
  local count, keep, outer = 0, nil, 0
  while true do
    outer = outer + 1
    if outer > M then break end
    local a = {v = 1, w = 2}
    local i = 0
    while true do
      i = i + 1
      if i > N then break end
      local t = {i, i}
      keep = t
      if i % 97 == 0 then count = count + a.w end
      count = count + a.v
    end
  end
  return count, keep ~= nil
end

-- the same with a numeric for loop as the outer loop
local function nested_break_for(N, M)
  local count, keep = 0, nil
  for outer = 1, M do
    local a = {v = 1, w = 2}
    local i = 0
    while true do
      i = i + 1
      if i > N then break end
      local t = {i, i}
      keep = t
      if i % 97 == 0 then count = count + a.w end
      count = count + a.v
    end
  end
  return count, keep ~= nil
end

-- `goto top` from the inner loop to the LOOP of an enclosing `repeat`
local function goto_repeat(N, M)
  local count, keep, outer = 0, nil, 0
  ::top::
  repeat
    outer = outer + 1
    if outer > M then break end
    local a = {v = 1, w = 2}
    local i = 0
    while true do
      i = i + 1
      if i > N then goto top end
      local t = {i, i}
      keep = t
      if i % 97 == 0 then count = count + a.w end
      count = count + a.v
    end
  until false
  return count, keep ~= nil
end

-- the inner loop reads a weak table (a weak trace clears dead slots)
local function nested_break_weak(N, M)
  local count, outer = 0, 0
  local w = setmetatable({}, {__mode = "v"})
  while true do
    outer = outer + 1
    if outer > M then break end
    local a = {v = 1, w = 2}
    local i = 0
    while true do
      i = i + 1
      if i > N then break end
      local t = {i, i}
      w[1] = t
      if i % 97 == 0 then count = count + a.w end
      count = count + a.v + (w[1] and 0 or 0)
    end
  end
  return count
end

local ok, c, k = pcall(nested_break, 6000, 100)
p("nested break", ok, c, k)
ok, c, k = pcall(nested_break_for, 6000, 100)
p("nested break, for outer", ok, c, k)
ok, c, k = pcall(goto_repeat, 6000, 100)
p("goto to repeat", ok, c, k)
ok, c = pcall(nested_break_weak, 6000, 100)
p("nested break, weak trace", ok, c)

-- A pending <close> variable of the enclosing body and the closing value of
-- a generic for sit below the inner loop's registers, so a weak trace's
-- loop-head clearing leaves them alone (5.4 syntax, hence load).
local tbc = assert(load([[
  local N, M = ...
  local w = setmetatable({}, {__mode = "v"})
  local closed, count = 0, 0
  local mt = {__close = function(o) closed = closed + o.v end}
  for outer = 1, M do
    local c <close> = setmetatable({v = 1}, mt)
    local i = 0
    while true do
      i = i + 1
      if i > N then break end
      w[1] = {i}
      count = count + c.v
    end
  end
  for _, x in next, {1, 2, 3}, nil, setmetatable({v = 10}, mt) do
    local i = 0
    while i < N do i = i + 1; w[1] = {i}; count = count + x - x + 1 end
  end
  return count, closed
]]))
p("pending close, weak trace", pcall(tbc, 3000, 50))
