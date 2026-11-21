--! Ephemeron convergence: a weak-key table's value is marked only when its
--! key is marked, and the marking repeats until no new key turns black, as
--! PUC's convergeephemerons/traverseephemeron. Never-clearable keys (strings,
--! numbers, booleans, the boxed integer) act as marked.
local function p(...) print(...) end

-- gc.lua:329-347 shape: a chain of keys that die, whose values point back
do
  local mt = {__mode = "k"}
  local a = {{10}, {20}, {30}, {40}}
  setmetatable(a, mt)
  local x = nil
  for i = 1, 100 do local n = {}; a[n] = {k = {x}}; x = n end
  collectgarbage()
  local n, i = x, 0
  while n do n = a[n].k[1]; i = i + 1 end
  p("chain", i)
  x = nil
  collectgarbage()
  for i = 1, 4 do a[i] = nil end
  p("leftover", next(a) ~= nil)
end

-- convergence through a value: keep -> v -> inner, then inner's own entry
do
  local mt = {__mode = "k"}
  local a = setmetatable({}, mt)
  local keep = {}
  local inner = {}
  a[keep] = {inner}
  a[inner] = {{42}}
  collectgarbage()
  p("converged", a[keep] ~= nil, a[inner] ~= nil, a[inner] and a[inner][1][1])
  keep, inner = nil, nil
  collectgarbage(); collectgarbage()
  p("converged-clean", next(a) == nil)
end

-- keys that are never cleared keep their entry
do
  local a = setmetatable({}, {__mode = "k"})
  a["str"] = {1}
  a[3] = {2}
  a[true] = {3}
  a[0x7fffffff00000001] = {4}
  collectgarbage(); collectgarbage()
  local s, n = {}, 0
  for k, v in next, a do n = n + 1; s[#s+1] = type(k) end
  table.sort(s)
  p("kept", n, table.concat(s, ","))
end

-- a dead key's entry goes in the same cycle, a live key's value stays
do
  local a = setmetatable({}, {__mode = "k"})
  local live = {}
  a[live] = {}
  do local dead = {}; a[dead] = {} end
  collectgarbage()
  local n = 0
  for k, v in next, a do n = n + 1 end
  p("one-cycle", n, a[live] ~= nil)
end

-- array part of an ephemeron table: values there have no key and are kept
do
  local a = setmetatable({{7}, {8}}, {__mode = "k"})
  collectgarbage()
  p("array", a[1] ~= nil, a[1] and a[1][1])
end
