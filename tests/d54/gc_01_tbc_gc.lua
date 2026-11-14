--! §4.2/§4.4 to-be-closed variables (<close>), __close order, GC + __gc
-- 5.4-only syntax in the last section (load() keeps the file parseable on 2.1).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function chunk(src)
  local f, err = load(src)
  if not f then return "PARSE_ERR: " .. tostring(err):gsub("^.-:%d+: ", "") end
  local ok, res = pcall(f)
  if not ok then return "RUN_ERR: " .. tostring(res):gsub("^.-:%d+: ", "") end
  return tostring(res)
end
p("tbc basic", chunk([[
  local log = {}
  do local x <close> = setmetatable({}, {__close=function() log[#log+1]="a" end}) end
  return table.concat(log, ",")
]]))
p("tbc order", chunk([[
  local log = {}
  do
    local a <close> = setmetatable({}, {__close=function() log[#log+1]="a" end})
    local b <close> = setmetatable({}, {__close=function() log[#log+1]="b" end})
  end
  return table.concat(log, ",")
]]))
p("tbc error", chunk([[
  local log = {}
  local ok, err = pcall(function()
    local a <close> = setmetatable({}, {__close=function() log[#log+1]="a" end})
    error("x")
  end)
  return tostring(ok) .. "," .. table.concat(log, ",")
]]))
p("tbc nonclosed", chunk([[
  local ok, err = pcall(function() local x <close> = 5 end)
  return tostring(ok)
]]))
p("const attrib", chunk("local x <const> = 3 return x"))
p("const assign", chunk("local x <const> = 3 x = 4 return x"))
-- GC: deterministic observations only (no finalizer ordering guarantees)
p("gc count", type(collectgarbage("count")))
p("gc options", pcall(collectgarbage, "generational"), pcall(collectgarbage, "incremental"),
  pcall(collectgarbage, "generational", 20, 100), pcall(collectgarbage, "incremental", 100, 200))
p("gc step", pcall(collectgarbage, "step", 10), pcall(collectgarbage, "collect"))
p("gc isrunning", type(collectgarbage("isrunning")), collectgarbage("stop"), collectgarbage("restart"))
p("gc setpause", pcall(collectgarbage, "setpause", 100), pcall(collectgarbage, "setstepmul", 200))
p("gc weak", (function()
  local w = setmetatable({}, { __mode = "v" })
  do local t = {} w[1] = t end
  collectgarbage("collect"); collectgarbage("collect")
  return w[1] == nil
end)())
p("gc weak k", (function()
  local w = setmetatable({}, { __mode = "k" })
  do local k = {} w[k] = 1 end
  collectgarbage("collect"); collectgarbage("collect")
  return next(w) == nil
end)())
p("gc finalizer", (function()
  local n = 0
  do local t = setmetatable({}, { __gc = function() n = n + 1 end }) end
  collectgarbage("collect"); collectgarbage("collect")
  return n
end)())
p("gc cycle finalizer", (function()
  local n = 0
  do
    local a, b = {}, {}
    a.b = b; b.a = a
    setmetatable(a, { __gc = function() n = n + 1 end })
  end
  collectgarbage("collect"); collectgarbage("collect")
  return n
end)())
p("gc resurrect", (function()
  local saved
  do local t = setmetatable({}, { __gc = function(o) saved = o end }) end
  collectgarbage("collect")
  local alive = saved ~= nil
  saved = nil
  collectgarbage("collect")
  return alive
end)())
