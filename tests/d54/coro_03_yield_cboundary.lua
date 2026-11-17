--! §2.4 coroutine.yield across a C-call boundary inside a coroutine says
--! "attempt to yield across a C-call boundary" (PUC 5.4); only a yield from
--! the main thread is "attempt to yield from outside a coroutine".
local function strip(msg) return (tostring(msg):gsub("^[^:]*:%d+: ", "")) end
coroutine.wrap(function()
  print("sort", pcall(table.sort, {3, 2, 1}, function(a, b) coroutine.yield() return a < b end))
end)()
coroutine.wrap(function()
  print("gsub", pcall(string.gsub, "abc", "%w", function(c) coroutine.yield() return c end))
end)()
local co = coroutine.create(function()
  local ok, err = pcall(function() return select(2, pcall(table.sort, {2, 1}, function() coroutine.yield() end)) end)
  return ok, err
end)
print("create", coroutine.resume(co))
print("main", pcall(coroutine.yield))
print("main-stripped", select(2, pcall(coroutine.yield)))
