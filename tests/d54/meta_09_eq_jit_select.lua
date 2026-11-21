--! modes: A,B
-- 5.4 __eq selection (lvm.c luaV_equalobj): the first operand's __eq, and
-- only if it has none, the second operand's; the handler is called with the
-- operands in source order. Compiled comparisons must select exactly like
-- the interpreter, for every pairing of metatables a loop meets.

local calls = {}
local function mk(tag, res)
  return {__eq = function(a, b)
    calls[tag] = (calls[tag] or 0) + 1
    return res
  end}
end
local mtA, mtB = mk("A", true), mk("B", false)
local mtN = {}                       -- a metatable without __eq
local objs = {setmetatable({}, mtA), setmetatable({}, mtB), {},
              setmetatable({}, mtN), setmetatable({}, mtA)}
local names = {"a", "b", "plain", "nometh", "a2"}

local function ne(a, b) return a ~= b end
local function eq(a, b) return a == b end

local res = {}
for rep = 1, 400 do
  for i = 1, #objs do
    for j = 1, #objs do
      local r1, r2 = eq(objs[i], objs[j]), ne(objs[i], objs[j])
      if rep == 400 then
        res[#res + 1] = names[i] .. "=" .. names[j] .. ":" ..
                        tostring(r1) .. "/" .. tostring(r2)
      end
    end
  end
end
print(table.concat(res, " "))
print("calls", calls.A, calls.B)

-- Userdata operands (io files carry no __eq; a proxy with __eq does).
local p1 = setmetatable({}, {__eq = function() return true end})
local function cmpio(x) return x == io.stdout, io.stdout == x end
local acc = 0
for k = 1, 300 do
  local a, b = cmpio(p1)
  if a then acc = acc + 1 end
  if b then acc = acc + 2 end
end
print("io", acc)

-- The selection switches while a loop runs: the trace must not keep the
-- handler of the pairing it was recorded with.
local function count(list, x)
  local n = 0
  for i = 1, #list do if list[i] == x then n = n + 1 end end
  return n
end
local list = {}
for i = 1, 300 do list[i] = objs[(i % 5) + 1] end
calls = {}
print("count", count(list, objs[3]), count(list, objs[1]), count(list, objs[2]),
      count(list, objs[4]))
print("calls2", calls.A, calls.B)
