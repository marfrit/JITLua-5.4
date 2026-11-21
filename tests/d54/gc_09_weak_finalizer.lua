--! Weak values are cleared in the atomic phase before finalizers run, as PUC
--! does (lgc.c atomic: clearbyvalues before separatetobefnz/markbeingfnz). A
--! weak key whose object is being finalized stays until clearbykeys after the
--! resurrection marks.
local function p(...) print(...) end

-- gc.lua:317-324 shape
do
  local t = {x = 10}
  local C = setmetatable({key = t}, {__mode = "v"})
  local C1 = setmetatable({[t] = 1}, {__mode = "k"})
  local a = {}
  a.x = t
  setmetatable(a, {__gc = function()
    p("v-gc", C.key == nil, type(next(C1)))
  end})
  a, t = nil
  collectgarbage(); collectgarbage()
  p("v-after", next(C) == nil, next(C1) == nil)
end

-- all-weak (kv) table: numeric value survives, collectable value is cleared
do
  local t = {}
  local W = setmetatable({[1] = t, [2] = 25}, {__mode = "kv"})
  local a = setmetatable({x = t}, {__gc = function()
    p("kv-gc", W[1] == nil, W[2] == 25, type(next(W)) == "number")
  end})
  a, t = nil
  collectgarbage(); collectgarbage()
  p("kv-after", next(W) == nil)
end

-- a weak value reachable only from the object being finalized: the value is
-- cleared before the finalizer, even though resurrection marks it afterwards
do
  local t = {}
  local W = setmetatable({key = t}, {__mode = "v"})
  local saved
  local a = setmetatable({x = t}, {__gc = function(o)
    saved = o
    p("res-gc", W.key == nil, type(saved.x))
  end})
  a, t = nil
  collectgarbage()
  p("res-after", W.key == nil, saved ~= nil)
  saved = nil
  collectgarbage(); collectgarbage()
end
