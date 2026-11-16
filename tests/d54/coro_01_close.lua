--! §4.2 coroutine.close + resume/yield error semantics (5.1-parseable part)
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("close exists", type(coroutine.close), type(coroutine.isyieldable))
local co = coroutine.create(function(a, b)
  coroutine.yield(a + b)
  error("boom")
end)
p("resume1", coroutine.resume(co, 1, 2))
p("status", coroutine.status(co))
p("resume2", coroutine.resume(co))
p("status dead", coroutine.status(co))
p("resume dead", coroutine.resume(co))
p("close dead", pcall(coroutine.close, co))
local co2 = coroutine.create(function() coroutine.yield(1) end)
coroutine.resume(co2)
p("close suspended", coroutine.close(co2), coroutine.status(co2))
-- LuaJIT C-function errors carry no caller location (PUC's close has one);
-- normalize the location prefix so both sides print the same wording.
local function closepair(f)
  local ok, e = pcall(f)
  return ok, ok or (e:gsub("^.-:%d+: ", ""))
end
p("close running", closepair(function() return coroutine.close(coroutine.running()) end))
p("close main", closepair(function() return coroutine.close((coroutine.running())) end))
p("close err type", pcall(coroutine.close, 5), pcall(coroutine.close, nil))
local co3 = coroutine.create(function() error({ code = 7 }) end)
local ok, err = coroutine.resume(co3)
p("error object", ok, type(err), err.code)
p("yield outside", pcall(coroutine.yield, 1))
p("wrap", (function()
  local w = coroutine.wrap(function() coroutine.yield(1); coroutine.yield(2) end)
  return w(), w()
end)())
p("wrap error", pcall(coroutine.wrap(function() error("x") end)))
p("isyieldable", coroutine.isyieldable(), (function()
  local co = coroutine.create(function() return coroutine.isyieldable() end)
  return select(2, coroutine.resume(co))
end)())
-- resume is an asm fast function in LuaJIT: its argument error carries no
-- caller location (PUC's does). Wrap in pcall and normalize the location.
local function errpair(f)
  local ok, e = pcall(f)
  e = ok or e:gsub("^.-:%d+: ", ""):gsub("'coroutine%.", "'")
  return ok, e
end
p("resume noncoro", errpair(function() return coroutine.resume(5) end))
p("close to-be-closed", (function()
  if not coroutine.close then return "no close" end
  local f = load([[
    local log = {}
    local co = coroutine.create(function()
      local x <close> = setmetatable({}, { __close = function() log[#log + 1] = "closed" end })
      coroutine.yield()
    end)
    coroutine.resume(co)
    coroutine.close(co)
    return table.concat(log, ",")
  ]])
  if not f then return "PARSE_ERR" end
  return f()
end)())
