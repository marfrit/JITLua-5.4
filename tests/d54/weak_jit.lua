--! Weak table reads must not be compiled into a loop that caches the value
--! across GC. A weak kv table plus a loop allocating garbage must make GC
--! progress and clear the entry; the iteration bound keeps a broken JIT from
--! hanging the harness. Mode A compares PUC, B the JIT with the interpreter.
local x = {[1] = {}}
setmetatable(x, {__mode = 'kv'})
local n = 0
while x[1] ~= nil and n < 5000 do
  local a = n..n..n..n   -- allocation drives the GC step
  n = n + 1
end
assert(x[1] == nil, "weak value was not collected")
assert(n < 5000, "loop hit the bound without GC progress")
print("weak-jit ok")
