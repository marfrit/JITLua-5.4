-- gc.lua:466-487. Two differences: (1) the 2^22-byte key stays an interned
-- string here (FORK string interning, docs/DIFFERENCES.md), so more memory is
-- counted after the weak kv table is cleared; (2) collectgarbage("count")
-- counts LuaJIT's own allocation grain, not PUC's. The absolute numbers differ
-- even before the weak table is cleared. Measured on x86_64 and aarch64.
local m = collectgarbage("count")
local a = setmetatable({}, {__mode = "kv"})
a[string.rep("a", 2^22)] = 25
a[string.rep("b", 2^22)] = {}
a[{}] = 14
print("after fill KB:", collectgarbage("count") - m)
collectgarbage()
print("after collect KB:", collectgarbage("count") - m)
local k, v = next(a)
print("preserved:", k == string.rep("a", 2^22), v == 25)
k = nil; a[ string.rep("a", 2^22) ] = nil
collectgarbage()
print("final KB:", collectgarbage("count") - m)
