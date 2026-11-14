--! §4.3 dump/reload must not change observable behavior (table borders).
--! Found by mode R: {1,nil,3} gets a different border after string.dump->load.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local t = { 1, nil, 3 }
p("border", #t)
p("concat", pcall(table.concat, t))
p("unpack", pcall(table.unpack, t))
local u = { 1, 2, nil, 4 }
p("border2", #u)
local v = {}
v[1] = 1; v[3] = 3
p("border3", #v)
p("rawlen", rawlen and rawlen(t) or "no rawlen")
