-- strings.lua:190-194. LuaJIT interns every string (FORK, docs/DIFFERENCES.md),
-- so two equal 300-byte strings have one address and "%p" prints the same
-- value; PUC does not intern long strings, so its "%p" values differ. The
-- assertions are `~=` (different) in PUC's suite.
local s1 = string.rep("a", 300)
local s2 = string.rep("a", 300)
print("getmetatable? same object:", s1 == s2)
print("p1 == p2:", string.format("%p", s1) == string.format("%p", s2))
local l1 = "x" .. string.rep("y", 400)
local l2 = "x" .. string.rep("y", 400)
print("long p1 == p2:", string.format("%p", l1) == string.format("%p", l2))
