--! modes: B
--! A __call-chain resolution that runs out of stack while vmeta_call sets the
--! call up must not escape pcall/xpcall: the protected call has to catch it
--! like any other runtime error. Also pin the non-function argument checks
--! (coroutine.wrap and the xpcall handler reject a table in PUC and here)
--! with a huge chain object, and pin that the program continues after the
--! caught overflow. LuaJIT-only: no PUC arm, -jon vs -joff must agree.
local function build(n)
  local u = function() return 0 end
  for i = 1, n do
    u = setmetatable({i}, {__call = u})
  end
  return u
end

local function norm(msg)
  return tostring(msg):gsub("^.-:%d+: ", "")
end

local u = build(70000)

-- pcall directly on the chain object (the target, not a wrapper)
local ok1, e1 = pcall(u)
print("pcall " .. tostring(ok1) .. " " .. norm(e1))

-- xpcall directly on the chain object; the handler sees the overflow
local ok2, e2 = xpcall(u, function(e) return norm(e) end)
print("xpcall " .. tostring(ok2) .. " " .. norm(e2))

-- coroutine.wrap rejects a non-function before any chain resolution
local ok3, e3 = pcall(coroutine.wrap, u)
print("wrap " .. tostring(ok3) .. " " .. norm(e3))

-- a chain object as the xpcall handler is also rejected as non-function
local ok4, e4 = pcall(xpcall, function() error("boom") end, u)
print("handler " .. tostring(ok4) .. " " .. norm(e4))

-- the program is still alive and can call the next chain
local u2 = build(2)
print("continued " .. tostring(u2("a")))
