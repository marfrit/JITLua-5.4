--! §2.6 table.concat on a table with __len calls __len first, also when an
--! end is given, and before the separator and the bounds are checked (PUC
--! ltablib.c tconcat: aux_getn, then luaL_optlstring/luaL_optinteger). This
--! tree skipped __len when an end was given and checked the separator first.
--! Printed: results, errors and the number of __len calls.
local calls = 0
local function proxy(len)
  return setmetatable({}, {
    __index = function(_, i) return "x" .. i end,
    __len = function() calls = calls + 1 return len end,
  })
end
local function p(label, ...)
  calls = 0
  local ok, r = pcall(table.concat, ...)
  print(label, ok, (tostring(r):gsub("^[^:]*:%d+: ", "")), "len calls " .. calls)
end
p("bad len, end given", proxy(1.5), ",", 1, 2)
p("bad len, no end", proxy(1.5), ",")
p("bad sep", proxy(2), {}, 1, 2)
p("bad start", proxy(2), ",", {}, 2)
p("end given", proxy(2), ",", 1, 3)
p("no end", proxy(2), ",")
p("string len", proxy("3"), "-", 2)
local r
calls = 0
local q = proxy(2)
for _ = 1, 100 do r = table.concat(q, ",", 1, 2) end
print("hot", r, "len calls " .. calls)
