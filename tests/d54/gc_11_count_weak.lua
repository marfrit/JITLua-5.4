--! collectgarbage("count") after a weak kv table is cleared: PUC returns to
--! the baseline once the last entry is gone (gc.lua:465-487). Two long string
--! keys, one with a number value (kept), one with a table value (cleared);
--! the count right after the fill is above the 2x the strings in KB, after
--! the collect one key is gone, and after erasing the last entry everything
--! is collected.
local function p(...) print(...) end
local undef = nil

collectgarbage(); collectgarbage()
local m = collectgarbage("count")
local a = setmetatable({}, {__mode = "kv"})
a[string.rep("a", 2^22)] = 25
a[string.rep("b", 2^22)] = {}
a[{}] = 14
p("filled", collectgarbage("count") > m + 2^13)
collectgarbage()
p("one-key", collectgarbage("count") >= m + 2^12 and
  collectgarbage("count") < m + 2^13)
local k, v = next(a)
p("kept", k == string.rep("a", 2^22), v == 25)
p("rest", next(a, k) == nil, a[string.rep("b", 2^22)] == undef)
a[k] = undef
k = nil
collectgarbage()
p("empty", next(a) == nil)
p("deadkey", a[string.rep("b", 100)] == undef)
p("final", collectgarbage("count") < m * 2 + 64)
