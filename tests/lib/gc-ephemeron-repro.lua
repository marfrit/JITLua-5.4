-- gc.lua:329-347. After x (the tail of the chain) is nil and a full collection
-- ran, PUC's ephemeron table has no entry left: next(a) == nil. LuaJIT's
-- weak-key algorithm (pre-5.4, not the converged ephemeron marking) leaves the
-- chain entries behind, so next(a) is not nil. The reachable chain is the same
-- (100 in both arms).
-- gc.lua 334-347: an ephemeron table whose keys point to values that die
local mt = {__mode = 'k'}
local a = {{10},{20},{30},{40}}; setmetatable(a, mt)
local x = nil
for i = 1, 100 do local n = {}; a[n] = {k = {x}}; x = n end
collectgarbage()
local n = x
local i = 0
while n do n = a[n].k[1]; i = i + 1 end
print("chain:", i)
x = nil
collectgarbage()
for i = 1, 4 do assert(a[i][1] == i * 10); a[i] = nil end
print("leftover entries:", next(a) ~= nil, "size hint:", #a)
