--! §2.6 table.concat on a table with __index/__len (PUC ltablib.c tconcat,
--! addfield) builds its result in a luaL_Buffer of the call. This tree built
--! it in the global temp buffer and kept the partial result there across
--! lua_geti, so an __index that used the buffer itself ('..',
--! string.format, a nested table.concat) or ran a collection (the atomic
--! phase frees the buffer) overwrote or lost it: "v1,v2,v3" came out as
--! "v3v3". Printed: the concatenations, in a loop that is compiled under -jon.
local function proxy(n, get)
  return setmetatable({}, {__index = function(_, i) return get(i) end,
                           __len = function() return n end})
end
local cases = {
  {"concat op", proxy(3, function(i) return "v" .. i end), ","},
  {"format", proxy(3, function(i) return string.format("<%d>", i) end), ","},
  {"nested concat", proxy(2, function(i) return table.concat({"a", "b", i}, "-") end), "|"},
  {"nested proxy", proxy(3, function(i)
     return table.concat(proxy(i, function(j) return "x" .. j end), ".") end), " / "},
  {"tostring", proxy(4, function(i) return tostring(i * 1.5) end), ""},
  {"numbers", proxy(5, function(i) return i % 2 == 0 and i / 2 or i * 2^40 end), ","},
  {"rep", proxy(3, function(i) return string.rep("ab", i, "+") end), ";"},
  {"long sep", proxy(3, function(i) return ("z"):rep(i) .. "." end), ("-"):rep(40)},
}
for _, c in ipairs(cases) do
  local r
  for _ = 1, 100 do r = table.concat(c[2], c[3]) end
  print(c[1], r)
end
-- An __index that only allocates (and drives the collector through its
-- atomic phase) while the concatenation is being built.
local alloc = proxy(50, function()
  for _ = 1, 200 do local _ = {} end
  return "w"
end)
local good = 0
for _ = 1, 300 do
  if table.concat(alloc, "", 1, 50) == string.rep("w", 50) then good = good + 1 end
end
print("allocating __index", good)
local full = proxy(5, function(i) collectgarbage() return "z" .. i end)
print("collect in __index", table.concat(full, ",", 1, 5))
-- Errors keep PUC's message (type and index of the bad value).
local bad = proxy(3, function(i) if i == 2 then return {} end return "ok" .. i end)
print(pcall(table.concat, bad, ","))
