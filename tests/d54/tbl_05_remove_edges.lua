--! §2.6 table.remove: PUC 5.4 tremove reads t[pos] with pos = pos or #t,
--! validates a given pos as (unsigned)pos-1 <= (unsigned)#t (so pos = #t+1 is
--! allowed, pos 0 and negatives with a non-empty table are not), shifts, and
--! then clears t[pos] at its value after the shift loop. The Lua emulation
--! skipped the whole pos==nil branch for an empty table and accepted pos 0.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

-- border 0: t[0] is the element to remove (size 0, pos = size = 0)
do
  local a = {[0] = "ban"}
  p("zero", #a, table.remove(a), a[0], #a)
end

-- pos 0 on a non-empty table is out of bounds
do
  local a = {10, 20, 30, 40}
  local ok = pcall(table.remove, a, 0)
  p("pos0", ok, #a, a[1], a[4])
end

-- pos = #t + 1 removes nothing and keeps t[#t]
do
  local a = {10, 20, 30, 40}
  p("past", table.remove(a, #a + 1), #a, a[4])
end

-- negative position is out of bounds
do
  local a = {10, 20}
  p("neg", pcall(table.remove, a, -1), #a)
end

-- a given pos = #t is valid and removes
do
  local a = {10, 20, 30}
  p("last", table.remove(a, #a), #a, a[#a])
end

-- no position on a non-empty table still removes the last element
do
  local a = {10, 20, 30}
  p("tail", table.remove(a), #a, a[#a])
end
