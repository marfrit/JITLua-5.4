--! §2.6 table.remove(t, nil): PUC tremove reads the position with
--! luaL_optinteger, so nil is "no position" and the last element is removed.
--! This tree required a number as soon as a second argument was passed, on
--! the plain-table path and on the metamethod path. Printed: the results, in
--! a loop that is compiled under -jon.
local r = {}
for i = 1, 100 do
  local t = {1, 2, 3}
  r[1] = table.remove(t, nil); r[2] = #t
end
print("plain", r[1], r[2])
local t = {}
print("empty", table.remove(t, nil), #t)
local store = {10, 20, 30, 40}
local p = setmetatable({}, {
  __index = function(_, i) return store[i] end,
  __newindex = function(_, i, v) store[i] = v end,
  __len = function() return #store end,
})
print("proxy", table.remove(p, nil), #store)
for i = 1, 100 do store[#store + 1] = i; r[3] = table.remove(p, nil) end
print("proxy hot", r[3], #store)
print(pcall(table.remove, {1}, false))
