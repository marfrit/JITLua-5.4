-- gc.lua:57-72, the `repeat u = {} until finish` loop of GC1. The finalizable
-- table sits in a dead stack slot that the conservative scan keeps alive, so
-- the loop never ends here; PUC ends it after 39 iterations (this probe stops
-- at 200000 and prints finish=false). See the dead-slot entry in
-- docs/DIFFERENCES.md; the runner bounds gc.lua and db.lua at 10 s.
-- the same, but keep the old value do-block scoped
local finish = false
local u
do
  u = setmetatable({}, {__gc = function() finish = true end})
end
local n = 0
repeat u = {}; n = n + 1 until finish or n > 200000
print("finish:", finish, "iterations:", n)
