--! §3.4.3 lua_isstring is true for every number (PUC lapi.c: cvt2str). This
--! tree left out 5.4 integers kept in the int64 box (outside the inline
--! range), so the library code that asks it rejected them: a string.gsub
--! replacement (function or table) of 1 << 60 raised "invalid replacement
--! value (a number)", a __tostring returning one raised "'__tostring' must
--! return a string" in luaL_tolstring, and table.concat on a table with
--! __index refused it. Printed: the results, also from a compiled loop.
local big = 1 << 60
local function p(label, f, ...)
  local ok, r = pcall(f, ...)
  print(label, ok, (tostring(r):gsub("^[^:]*:%d+: ", "")))
end
p("gsub function", string.gsub, "ab", ".", function() return big end)
p("gsub table", string.gsub, "ab", ".", {a = big, b = -big})
p("gsub small", string.gsub, "ab", ".", function() return 7 end)
local obj = setmetatable({}, {__tostring = function() return big end})
p("print", print, obj)
p("format %s", string.format, "%s", obj)
p("tostring", tostring, obj)
local prox = setmetatable({}, {__index = function(_, i) return big + i end,
                               __len = function() return 3 end})
p("concat", table.concat, prox, ",")
local r
for _ = 1, 100 do r = string.gsub("xyz", "y", function() return big end) end
print("hot", r)
