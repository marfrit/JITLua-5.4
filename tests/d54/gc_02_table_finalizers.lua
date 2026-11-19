--! §2.5.3/§2.5.4: __gc finalizers for tables (order, resurrection, weak
--! tables, errors, late marking, close). Deterministic output only.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function gc2()
  collectgarbage("collect")
  collectgarbage("collect")
end

-- finalizers run in reverse order of marking
p("order", (function()
  local log = {}
  local function mk(name)
    return setmetatable({}, {__gc = function() log[#log+1] = name end})
  end
  local a = mk("a")
  local b = mk("b")
  local c = mk("c")
  a, b, c = nil, nil, nil
  gc2()
  return table.concat(log, ",")
end)())

-- a finalized object is resurrected for the call and freed on a later cycle
p("resurrect", (function()
  local saved, n = nil, 0
  local t = setmetatable({}, {__gc = function(o) n = n + 1; saved = o end})
  t = nil
  collectgarbage("collect")
  local alive = saved ~= nil
  local n1 = n
  saved = nil
  gc2()
  return alive, n1, n
end)())

-- resurrected objects are removed from weak values before the finalizer
p("weakv", (function()
  local w = setmetatable({}, {__mode = "v"})
  local log = {}
  local t = setmetatable({}, {__gc = function() log[#log+1] = "fin" end})
  w[1] = t
  t = nil
  collectgarbage("collect")
  return w[1] == nil, table.concat(log, ",")
end)())

-- a still-reachable table marked for finalization stays in weak values
p("weakv_live", (function()
  local t = setmetatable({}, {__gc = function() end})
  local w = setmetatable({}, {__mode = "v"})
  w[1] = t
  gc2()
  local alive = w[1] ~= nil
  t = nil
  return alive
end)())

-- ... but from weak keys only in the next collection
p("weakk", (function()
  local w = setmetatable({}, {__mode = "k"})
  local log = {}
  local t = setmetatable({}, {__gc = function()
    log[#log+1] = "k" .. tostring(next(w) ~= nil)
  end})
  w[t] = true
  t = nil
  collectgarbage("collect")
  local during = table.concat(log, ",")
  gc2()
  return during, next(w) == nil
end)())

-- an error in __gc is a warning, not a propagated error
p("gcerr", (function()
  local ok, err = pcall(function()
    local t = setmetatable({}, {__gc = function() error("boom") end})
    t = nil
    gc2()
  end)
  return ok, err
end)())

-- collectgarbage() inside __gc works (does not recurse or crash)
p("gcinside", (function()
  local n = 0
  local t = setmetatable({}, {__gc = function()
    n = n + 1
    collectgarbage("collect")
  end})
  t = nil
  gc2()
  return n
end)())

-- a __gc added to the metatable after setmetatable does not mark the table
p("late", (function()
  local log = {}
  local mt = {}
  local t = setmetatable({}, mt)
  mt.__gc = function() log[#log+1] = "late" end
  t = nil
  gc2()
  return #log
end)())

-- ... and a trace that recorded setmetatable with a __gc-free metatable must
-- not skip the marking after the metatable gains __gc (guard invalidation)
p("latejit", (function()
  local n = 0
  local mt = {tag = "J"}
  for i = 1, 3000 do local o = setmetatable({}, mt) end
  mt.__gc = function() n = n + 1 end
  for i = 1, 20 do local o = setmetatable({}, mt) end
  gc2()
  return n
end)())

-- many finalizable tables (exercises the interpreter and the JIT path)
p("hot", (function()
  local n = 0
  local mt = {__gc = function() n = n + 1 end}
  for i = 1, 2000 do
    local t = setmetatable({}, mt)
  end
  gc2()
  return n
end)())

-- a hot constructor loop with a __gc-free metatable must still run (and the
-- trace must not be turned into an abort/stitch by the finalizer check)
p("hotnogc", (function()
  local mt = {tag = "M"}
  local s = 0
  for i = 1, 50000 do
    local t = setmetatable({}, mt)
    t.v = i
    s = s + t.v
  end
  return s
end)())

-- lua_close runs the remaining finalizers (printed at exit)
p("close_setup", "ok")
_G.__gc_at_close = setmetatable({}, {__gc = function()
  print("close_finalizer")
end})
