--! modes: A,B
-- Lua 5.4 has no __ipairs: ipairs(t) returns its own iterator, t and 0
-- whatever the metatable of t says (PUC 5.4.9 lbaselib.c ipairs), and only
-- pairs honours a metamethod (__pairs). The interpreter does that; a trace
-- that records the call of ipairs must do the same. Recording a call of
-- __ipairs instead puts a frame into the trace that the VM never pushed:
-- every slot of the trace is then off by that frame (seen with Penlight's
-- tablex.readonly, whose proxy tables still carry __ipairs: an assertion in
-- the recorder, or a crash, in about one run in ten).
--
-- Each loop is hot, so the call site is compiled; -Ohotexit=1 makes the
-- side traces start early as well.

if jit and jit.opt then jit.opt.start("hotexit=1") end

local called = 0
local function mm(t)
  called = called + 1
  return function() end, t, 0
end

-- The shape of tablex.readonly: a proxy with __index, __ipairs and __pairs.
local function readonly(t)
  return setmetatable({}, {
    __index = t,
    __newindex = function() error("readonly") end,
    __len = function() return #t end,
    __pairs = function() return pairs(t) end,
    __ipairs = mm,
  })
end

-- 1. ipairs of a table whose metatable has __ipairs, in a hot loop.
do
  local t = setmetatable({1, 2, 3}, {__ipairs = mm})
  local acc, n = 0, 0
  for i = 1, 300 do
    for k, v in ipairs(t) do acc = acc + k * v; n = n + 1 end
  end
  print("plain", acc, n, called)
end

-- 2. The proxy: ipairs goes through __index, pairs through __pairs.
do
  local ro = readonly({1, 2, 3, hello = "world"})
  local acc, n, keys = 0, 0, 0
  for i = 1, 300 do
    local r = {}
    for k, v in ipairs(ro) do r[k] = v end
    acc = acc + #r + r[1] + r[3]
    for k, v in pairs(ro) do keys = keys + 1 end
    n = n + 1
  end
  print("proxy", acc, n, keys, called)
end

-- 3. The call site first sees tables without the metamethod, then with it,
-- and the other way round.
do
  local plain, with = {4, 5, 6}, setmetatable({7, 8}, {__ipairs = mm})
  local acc = 0
  for i = 1, 400 do
    local t = (i > 200) and with or plain
    for k, v in ipairs(t) do acc = acc + v end
    local u = (i > 200) and plain or with
    for k, v in ipairs(u) do acc = acc - k end
  end
  print("mixed", acc, called)
end

-- 4. The trace comes back through returns into the frame that calls ipairs
-- (a compare function that recurses, called from a check function).
do
  local function same(a, b)
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local bad = 0
  local function check(x, y) if not same(x, y) then bad = bad + 1 end end
  local ro = readonly({1, 2, 3, {4, {5}}})
  local acc = 0
  for i = 1, 300 do
    local r = {}
    for k, v in pairs(ro) do r[k] = v end
    check(r, {1, 2, 3, {4, {5}}})
    r = {}
    for k, v in ipairs(ro) do r[k] = v end
    check(r, {1, 2, 3, {4, {5}}})
    acc = acc + #r
  end
  print("returns", acc, bad, called)
end

-- 5. The results of the call itself.
do
  local t = setmetatable({}, {__ipairs = mm})
  local it0 = ipairs({})
  local ok = 0
  for i = 1, 300 do
    local it, s, c, extra = ipairs(t)
    if it == it0 and s == t and c == 0 and extra == nil and
       select('#', ipairs(t)) == 3 then ok = ok + 1 end
  end
  print("results", ok, called)
end
