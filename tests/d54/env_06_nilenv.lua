--! 5.4 nil environment, dedicated regression: load(chunk, nil, nil, nil) sets
--! the chunk's _ENV to nil (PUC stores it as the _ENV upvalue), so any global
--! access errors with "attempt to index a nil value (upvalue '_ENV')".
--! Before the fix this SEGFAULTED in the VM: the GGET/GSET fast path fed a
--! NULL env table straight to the table lookup. Modes A/B/R (PUC-comparable).
local function norm(s) return (tostring(s):gsub("^.-:%d+: ", "")) end
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " "))
end
local function try(label, f)
  local ok, e = pcall(f)
  p(label, ok, ok and e or norm(e))
end

p("env is nil", load("return _ENV", nil, nil, nil)() == nil)
try("nil read", function() return load("return x", nil, nil, nil)() end)
try("nil write", function() return load("x = 1", nil, nil, nil)() end)
try("nil index", function() return load("return x.y", nil, nil, nil)() end)
try("nil call", function() return load("x()", nil, nil, nil)() end)
try("nil nested", function()
  local f = load("return function() return x end", nil, nil, nil)
  return f()()
end)
-- loadfile/load with a nil env and a chunk that never touches _ENV is fine.
p("load ok", (pcall(load, "return 1", nil, nil, nil)))
