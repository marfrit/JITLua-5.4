--! modes: B,R
--! Recursion through a callable object ends in "stack overflow" at the stack
--! limit, like recursion through a plain function. The depth it reaches must
--! not depend on where the frames happen to sit: the __call setup asks for
--! one more slot above the call's arguments, not for the distance from
--! wherever the last C call left L->top. LuaJIT-only (PUC's limit differs);
--! the depths are not printed because compiled code uses other frame sizes.
local unpack = table.unpack
local lo, hi
for pad = 0, 11 do
  local reached = 0
  local obj = setmetatable({}, {__call = function(self, n)
    reached = n
    return 1 + self(n + 1)
  end})
  local co = coroutine.wrap(function(...) return pcall(obj, 1) end)
  local ok, err = co(unpack({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}, 1, pad))
  assert(ok == false and tostring(err):find("stack overflow"), tostring(err))
  lo = (lo == nil or reached < lo) and reached or lo
  hi = (hi == nil or reached > hi) and reached or hi
end
assert(lo > 1000, "recursion ended early: " .. lo)
assert((hi - lo) * 50 < hi,
       "depth depends on the alignment: " .. lo .. " .. " .. hi)
print("depth spread ok")
