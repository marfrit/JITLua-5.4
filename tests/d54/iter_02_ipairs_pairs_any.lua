--! §iter ipairs/pairs take any value (PUC luaL_checkany): the iterator is
--! returned, and the error for a non-table comes on the first step, from the
--! real operation (lua_geti for ipairs, next for pairs). 5.4 also honours
--! __pairs on tables and ignores __ipairs. Differential against PUC 5.4.9.
local function show(v)
  local s = tostring(v)
  s = s:gsub("0x%x+", "0xADDR")                  -- addresses first
  s = s:gsub("builtin#%d+", "0xADDR")             -- C function rendering
  return s
end
local function p(label, ...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = show((select(i, ...))) end
  print(label .. " | n=" .. n .. " | " .. table.concat(t, ","))
end
local function norm(e)
  local s = tostring(e)
  s = s:gsub("^.-:%d+: ", "")
  return s
end
local function q(label, f, ...)
  local ok, a, b = pcall(f, ...)
  print(label .. " | ok=" .. tostring(ok) .. " | " ..
	(ok and (show(a) .. "," .. show(b)) or norm(a)))
end

p("ipairs(1)", ipairs(1))
q("ipairs iter on number", (function(f, s, c) return f(s, c) end),
  ipairs(1))
p("ipairs('x')", ipairs("x"))
q("ipairs iter on string", (function(f, s, c) return f(s, c) end),
  ipairs("x"))

-- A userdata with __index (the standard file handle) is iterable: index 1 is
-- missing, so the first step returns nil, no error.
p("ipairs(io.stdout)", ipairs(io.stdout))
q("ipairs iter on userdata", (function(f, s, c) return f(s, c) end),
  ipairs(io.stdout))

p("pairs(1)", pairs(1))
q("pairs iter on number", (function(f, s, c) return f(s, c) end),
  pairs(1))
q("pairs iter on userdata", (function(f, s, c) return f(s, c) end),
  pairs(io.stdout))

-- __pairs still wins on a table, and ipairs ignores __ipairs.
local t = setmetatable({ 10, 20 }, {
  __pairs = function() return function() return nil end, "s", "t" end,
  __ipairs = function() return nil, "ip", "ctl" end,
})
local f, s, c = pairs(t)
print("pairs __pairs", type(f), s, c, f())
local f2, s2, c2 = ipairs(t)
print("ipairs ignores __ipairs", type(f2), s2, c2)
print("ipairs values", f2(t, 0), f2(t, 1), f2(t, 2))

-- Plain table iterators still have the 5.4 shape.
p("ipairs(table)", ipairs({ 7 }))
p("pairs(table)", pairs({}))
