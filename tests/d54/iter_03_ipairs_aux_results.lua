--! §iter the ipairs iterator returns one nil at the end (PUC ipairsaux:
--! lua_geti pushed nil, "return (lua_geti(...) == LUA_TNIL) ? 1 : 2"), and
--! compiled code agrees: the recorder used to record no result at all, so a
--! call that keeps every result picked up a stale stack slot.
local aux, t0 = ipairs({})
local t = {10, 20, 30}
local function cnt(...) return select("#", ...) end
local r, n, a, b
for i = 1, 300 do r = {aux(t, 3)} end
print("ctor at end", #r, r[1])
for i = 1, 300 do r = {aux(t, 2)} end
print("ctor inside", #r, r[1], r[2])
for i = 1, 300 do n = select("#", aux(t, 3)) end
print("select at end", n)
for i = 1, 300 do n = cnt(aux(t, 3)) end
print("vararg at end", n)
for i = 1, 300 do n = cnt(aux(t, 1)) end
print("vararg inside", n)
for i = 1, 300 do a, b = aux(t, 3) end
print("two results", a, b)
for i = 1, 300 do r = {"s", aux(t, 3)} end
print("ctor tail", #r, r[1], r[2])
for i = 1, 300 do r = {aux(t, 3), "e"} end
print("ctor head", #r, r[1], r[2])
for i = 1, 300 do r = tostring(aux(t, 3)) end
print("tostring", r)
for i = 1, 300 do r = type(aux(t, 3)) end
print("type", r)
-- the position alternates between the end and the inside of one loop
local acc = 0
for i = 1, 600 do
  local k = (i % 2 == 0) and 3 or 1
  acc = acc + cnt(aux(t, k))
end
print("alternating", acc)
-- the usual loop still ends
local s = 0
for rep = 1, 100 do for i, v in ipairs(t) do s = s + v end end
print("loop", s)
