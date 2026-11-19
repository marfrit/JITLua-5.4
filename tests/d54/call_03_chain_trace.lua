--! modes: B
--! The __call chain in hot loops: the recorder must either record the chain
--! in its slot model or exit the trace cleanly. The common depth-1 chain must
--! stay monomorphic and compile; a depth-2 chain and a deep chain must still
--! produce the interpreter's results. LuaJIT-only: no PUC arm, -jon vs -joff.
local function finish(...)
  local n = select("#", ...)
  local s = 0
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "table" then s = s + v[1] else s = s + v end
  end
  return s + n * 1000
end

local function chain(n, final)
  local u = final
  for i = 1, n do u = setmetatable({i}, {__call = u}) end
  return u
end

-- depth 1: one object, then a plain Lua function
local c1 = chain(1, finish)
local s1 = 0
for i = 1, 2000 do s1 = s1 + c1(i) end
print("depth1 " .. s1)

-- depth 2: object -> object -> function
local c2 = chain(2, finish)
local s2 = 0
for i = 1, 2000 do s2 = s2 + c2(i) end
print("depth2 " .. s2)

-- tail position, depth 1 and depth 2
local t1 = chain(1, finish)
local function tail1(x) return t1(x) end
local s3 = 0
for i = 1, 2000 do s3 = s3 + tail1(i) end
print("tail1 " .. s3)
local t2 = chain(2, finish)
local function tail2(x) return t2(x) end
local s4 = 0
for i = 1, 2000 do s4 = s4 + tail2(i) end
print("tail2 " .. s4)

-- a deep chain in a hot loop exceeds the recorder's slot budget; the trace
-- exits cleanly and the interpreter result is unchanged
local c100 = chain(100, finish)
local s5 = 0
for i = 1, 300 do s5 = s5 + c100(i) end
print("depth100 " .. s5)
