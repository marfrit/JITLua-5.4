-- gc.lua:317-324. PUC 5.4 clears the weak *value* of a table before the
-- finalizer of that value runs: inside __gc, C.key is nil. LuaJIT clears weak
-- values during sweep, after finalizers, so the finalizer here still sees the
-- table. PUC also keeps the weak-*key* entry C1 alive (its key, the table, is
-- the object being finalized): both sides print "table". After the second
-- collectgarbage both sides have emptied C and C1.
local t = {x = 10}
local C = setmetatable({key = t}, {__mode = 'v'})
local C1 = setmetatable({[t] = 1}, {__mode = 'k'})
local a = {}
a.x = t
setmetatable(a, {__gc = function(u)
  print("in __gc: C.key =", C.key, "C1 next =", type(next(C1)))
end})
a, t = nil
collectgarbage()
collectgarbage()
print("after: C next =", next(C), "C1 next =", next(C1))
