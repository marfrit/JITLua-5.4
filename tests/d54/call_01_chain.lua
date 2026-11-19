--! §4.2 __call chains (calls.lua lines 171/193): calling a value whose
--! __call is itself a callable table chains, prepending each object as an
--! argument, innermost first, and ends at the first function. Covered here:
--! depth 1/2/100/10000, argument order, C-function tail, non-tail tail call,
--! pcall(obj, ...), coroutine.wrap (small stack), and a chain that ends
--! without a callable object (the error names the object at that level).
local function parts(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "table" then t[i] = tostring(v[1]) else t[i] = tostring(v) end
  end
  return n .. " " .. table.concat(t, " ")
end

local function chain(n, final)
  local u = final or parts
  for i = 1, n do
    u = setmetatable({i}, {__call = u})
  end
  return u
end

-- depth 1, 2, 100: n chain objects first, innermost first, then the args
for _, n in ipairs{1, 2, 100} do
  local u = chain(n)
  local r = u("a", "b", "c")
  print("depth " .. n .. " " .. r)
end

-- depth 10000: the call itself is not the recursion (calls.lua uses a chain
-- ending in a tail-recursive Lua function); the argument count must include
-- all 10000 prepended objects.
local u = chain(10000, function(...) return select("#", ...) end)
print("depth 10000 " .. u("a"))

-- tail call through a chain in a new coroutine (calls.lua line 187 shape)
local n = 100
local function down()
  if n == 0 then return 1023 end
  n = n - 1
  return down()
end
local u = chain(100, down)
print("tail coro " .. tostring(coroutine.wrap(function() return u() end)()))
print("tail direct " .. tostring(u()))

-- pcall(obj, ...) and pcall(function() return obj(...) end)
local u2 = chain(2)
print("pcall obj " .. tostring(select(2, pcall(u2, "a", "b"))))
print("pcall tail " .. tostring(select(2, pcall(function() return u2("x") end))))

-- a chain ending in a C function: all prepended objects and the real
-- arguments reach it, in order (calls.lua N=20 table.pack block)
local N = 20
local u20 = table.pack
for i = 1, N do
  u20 = setmetatable({i}, {__call = u20})
end
local Res = u20("a", "b", "c")
print("cfunc n " .. Res.n)
print("cfunc first " .. Res[1][1] .. " last " .. Res[N][1] .. " args " .. Res[N + 1] .. Res[N + 2] .. Res[N + 3])

-- a chain that ends without a callable object names the failing object
local last = setmetatable({}, {__call = 3})
local mid = setmetatable({i = 7}, {__call = last})
local ok, msg = pcall(function() return mid() end)
print("badcall " .. tostring(ok) .. " " .. tostring(msg:match("attempt to call a [%w ]+ value")))
