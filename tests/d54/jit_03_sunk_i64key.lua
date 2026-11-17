--! §4.1 Sunk allocations restored after a side exit (-O3 with sink): a store
--! with a widened int64 constant key must be re-done with the 5.4 integer
--! key, not with the FFI cdata that lj_ir_kvalue builds for IR_KINT64.
--! Before the fix next(t) returned a cdata key and a later full GC crashed
--! without the ffi library loaded. Mode B at opt 3 is the trigger.
local function f(n)
  local r
  for i = 1, n do
    local t = {}
    t[1099511627776] = i
    if i == n then r = t end
  end
  return r
end
local t = f(300)
print("pos", type(next(t)), t[1099511627776], math.type(next(t)))
local function g(n)
  local r
  for i = 1, n do
    local t = {}
    t[-1099511627776] = i
    if i == n then r = t end
  end
  return r
end
t = g(300)
print("neg", type(next(t)), t[-1099511627776], math.type(next(t)))
local function h(n)
  local r
  for i = 1, n do
    local t = {a = 1}
    t[1099511627776] = i
    if i == n then r = t end
  end
  return r
end
t = h(300)
print("tdup", t.a, t[1099511627776], math.type(t[1099511627776]))
local k = 0
for key in pairs(t) do if math.type(key) == "integer" then k = k + 1 end end
print("tdup-intkeys", k)
collectgarbage()
collectgarbage()
print("gc ok")
