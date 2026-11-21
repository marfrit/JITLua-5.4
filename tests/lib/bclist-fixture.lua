-- Fixture for tests/lib/bclist-check.lua: loops (FORL/ITERL/LOOP back
-- edges, loop exits) and forward jumps (if/else, and/or, break, goto).
local function f(t, n)
  local s = 0
  for i = 1, n do
    if t[i] then s = s + i else s = s - 1 end
  end
  for k, v in pairs(t) do
    if v == 3 then break end
    s = s + (v and 1 or 2)
  end
  local i = 0
  while i < n do
    i = i + 1
    if i % 3 == 0 then goto continue end
    s = s + i
    ::continue::
  end
  repeat s = s - 1 until s < 10 or n == 0
  return s
end
return f
