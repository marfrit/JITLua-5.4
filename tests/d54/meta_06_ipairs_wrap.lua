--! §2.2 ipairs: the control variable is a 5.4 integer and wraps (PUC's
--! ipairsaux does lua_intop(+, i, 1) on an integer). LuaJIT truncated the key
--! to int32 and never got past math.maxinteger, so the wrapped key
--! math.mininteger never found a table entry.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local f = ipairs{}
p("same", type(ipairs{}) == "function" and ipairs{} == ipairs{})

local a = {[math.mininteger] = "min", [math.maxinteger] = "max"}
p("max", f(a, math.maxinteger))
p("min", f(a, math.mininteger))
p("wrapback", f(a, math.maxinteger - 1))
p("plain", f({10, 20}, 1))
p("stop", f({10, 20}, 2))

-- a float key truncates in the interpreter (documented difference), but must
-- not reach a stale int32 value
p("float", f({10, 20}, 1.0))

-- a table with __index keeps the 5.4 integer key and wraps as well
local proxy = setmetatable({}, {__index = function(_, k)
  return k == math.mininteger and "min" or nil
end})
p("proxy", f(proxy, math.maxinteger))
