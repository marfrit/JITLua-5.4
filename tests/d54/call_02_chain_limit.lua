--! modes: B
--! The __call chain is bounded by the Lua stack, like PUC 5.4 (PUC's own
--! LUAI_MAXSTACK is larger, so the depth is implementation-defined). A chain
--! longer than this VM's stack must raise a catchable "stack overflow", never
--! crash, and the interpreter and JIT must agree. LuaJIT-only: no PUC arm.
local function build(n)
  local u = function() return 0 end
  for i = 1, n do
    u = setmetatable({i}, {__call = u})
  end
  return u
end

local u = build(70000)  -- built outside pcall; the chain call is protected
local ok, err = pcall(function() return u() end)
assert(not ok)
assert(tostring(err):find("stack overflow"), tostring(err))
print("limit ok " .. tostring(ok))
print("limit msg " .. tostring(err):gsub("^.-:%d+: ", ""))
