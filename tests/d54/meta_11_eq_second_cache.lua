--! §meta '==' on two different tables when the first has no __eq: the
--! second operand's handler decides, also right after the interpreter has
--! cached "no __eq" for both metatables and one of them gains the handler.
local calls = 0
local mt1, mt2 = {}, {}
local a, b = setmetatable({}, mt1), setmetatable({}, mt2)
local plain = {}
local n = 0
for i = 1, 300 do
  if i == 100 then mt2.__eq = function() calls = calls + 1 return true end end
  if i == 200 then mt2.__eq = nil end
  if i == 250 then mt1.__eq = function() calls = calls + 100000 return false end end
  if a == b then n = n + 1 end
  if a ~= b then n = n + 1000 end
  if plain == b then n = n + 1000000 end
  if b ~= plain then n = n + 1 end
end
print(n, calls)
local u1, u2 = io.stdout, io.stderr
local k = 0
for i = 1, 100 do if u1 == u2 then k = k + 1 end if u1 ~= u2 then k = k + 10 end if u1 == u1 then k = k + 100 end end
print(k)
local x, y = {}, {}
k = 0
for i = 1, 100 do
  if i == 50 then setmetatable(y, {__eq = function() return true end}) end
  if x == y then k = k + 1 end
  if y ~= x then k = k + 100 end
end
print(k)
