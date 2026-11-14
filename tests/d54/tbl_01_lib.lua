--! §4.2 table.move/pack/unpack(i,j)/concat/#; vararg semantics incl. #...
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("move", table.concat(table.move({ 1, 2, 3, 4, 5 }, 2, 4, 1), ","))
p("move overlap", table.concat(table.move({ 1, 2, 3, 4, 5 }, 1, 3, 2), ","))
p("move dest", table.concat(table.move({ 1, 2, 3 }, 1, 3, 1, {}), ","))
p("move empty", table.concat(table.move({ 1, 2, 3 }, 2, 1, 1), ","))
p("move err", pcall(table.move, {}, 1, 2, 0), pcall(table.move, nil, 1, 1, 1))
p("pack", (function() local t = table.pack(1, nil, 3) return t.n, t[1], t[2], t[3] end)())
p("unpack", table.unpack({ 1, 2, 3 }))
p("unpack ij", table.unpack({ 1, 2, 3, 4 }, 2, 3))
p("unpack neg", table.unpack({ 1, 2, 3 }, -1))
p("unpack n", table.unpack({ 1, 2, 3 }, 1, 5))
p("unpack err", pcall(table.unpack, nil), pcall(table.unpack, {}, 1, 2 ^ 62))
p("concat", table.concat({ 1, 2, 3 }, "-"), table.concat({ 1, 2, 3 }, "-", 2),
  table.concat({ 1, 2, 3 }, "-", 1, 2), table.concat({}, ","))
p("concat err", pcall(table.concat, { {} }), pcall(table.concat, { 1, nil, 3 }))
p("insert remove", (function()
  local t = { 1, 2, 3 }
  table.insert(t, 2, 9); local a = table.concat(t, ",")
  local r = table.remove(t, 2); local b = table.concat(t, ",")
  table.insert(t, 4); local c = table.concat(t, ",")
  return a, r, b, table.remove(t), c
end)())
p("sort", table.concat((function() local t = { 3, 1, 2 } table.sort(t) return t end)(), ","))
p("sort cmp", table.concat((function() local t = { 3, 1, 2 } table.sort(t, function(a, b) return a > b end) return t end)(), ","))
p("sort err", pcall(table.sort, { 1, "a" }), pcall(table.sort, { 1, 2 }, function() return true end))
local function va(...)
  p("vararg n", select("#", ...), #table.pack(...))
  p("vararg select", select(2, ...))
  p("vararg select neg", select(-1, ...))
  local a, b = ...
  p("vararg first", a, b)
  p("vararg braces", #{...}, #{ ... }, (#{ ... }))
  p("vararg forward", (function(...) return select("#", ...) end)(...))
end
va(1, nil, 3)
va()
p("table.create ext", type(table.create))
p("len holes", #{ 1, 2, nil, 4 }, #{ nil, 2, 3 }, #{ 1, nil })
