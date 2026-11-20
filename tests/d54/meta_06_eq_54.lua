--! §2.5.1: equality in 5.4 selects the __eq handler like any other event
--! (lobject.c luaV_equalobj): the first operand's handler is used, and only
--! when it has none, the second one's; the call gets the operands in source
--! order. LuaJIT applied the 5.1 rule instead: both operands had to carry the
--! same __eq, so a plain table compared against one with a handler never
--! called it. PUC's suite checks this in events.lua:299.
local log
local function mk(tag, fn)
  return setmetatable({tag = tag}, {__eq = fn or function(a, b)
    log[#log+1] = tostring(a.tag) .. "/" .. tostring(b.tag)
    return a.tag == b.tag
  end})
end
local function reset() log = {}; return log end

reset()
local x = mk("x")
local y = mk("y")
local plain = {tag = "x"}

print("left only", x == plain, log[1])
reset()
print("right only", plain == x, log[1])
reset()
print("both, same handler", x == mk("x"), log[1])
reset()
print("both, different handler", x == y, log[1])
reset()
local second = {__eq = function(a, b) log[#log+1] = "second"; return true end}
print("first wins", x == setmetatable({tag = "x"}, second), log[1])

-- non-boolean handler result is taken as its truth value
local a = setmetatable({n = 1}, {__eq = function() return "yes" end})
local b = setmetatable({n = 1}, getmetatable(a))
print("truthy", a == b, not (a ~= b))
print("same table", rawequal(a, a), a == a)

-- events.lua's Set: the handler consumes the right operand, so the call order
-- is observable even with a single handler.
local function Set(...)
  local t, n = {}, select("#", ...)
  for i = 1, n do t[select(i, ...)] = true end
  return setmetatable(t, {__eq = function(p, q)
    for k in pairs(p) do
      if not q[k] then return false end
      q[k] = nil
    end
    return next(q) == nil
  end})
end
local rawSet = function(...)
  local t, n = {}, select("#", ...)
  for i = 1, n do t[select(i, ...)] = true end
  return t
end
print("set == raw", Set{1,3,5,1} == rawSet{3,5,1})
print("raw == set", rawSet{3,5,1} == Set{1,3,5,1})
print("ok")
