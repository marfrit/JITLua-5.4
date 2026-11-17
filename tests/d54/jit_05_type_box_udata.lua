--! §4.1 A boxed 64-bit integer is a GCudata with the userdata type tag, so
--! the type guard of a userdata load admits it. Recorders that decide from a
--! record-time userdata argument (type, getmetatable, debug.getmetatable,
--! rawequal) must guard the udtype too. Mode B at every opt level compares
--! the compiled loops with the interpreter; mode A with PUC.
local ud = io.stdout
local B = (1 << 50) + 3
local W = (1 << 40) + 3

-- ALOAD: the value comes out of a table.
local tv = { B, ud, W, ud }
local c = { number = 0, userdata = 0 }
for i = 1, 400 do local t = type(tv[(i % 4) + 1]); c[t] = c[t] + 1 end
print("aload", c.number, c.userdata)

-- SLOAD: the value is a function argument alternating between the two.
local function ty(v) local n = 0 for i = 1, 100 do if type(v) == "number" then n = n + 1 end end return n end
local sn = 0
for i = 1, 8 do sn = sn + ty((i % 2 == 1) and ud or B) end
print("sload", sn)

-- Loop with a real userdata first, then boxes (the trace is recorded on
-- the userdata and must exit for the box).
local tv2 = { ud, ud, ud, ud, B, B, B, B }
local nn, nu = 0, 0
for i = 1, 400 do
  local v = tv2[(i % 8) + 1]
  if type(v) == "number" then nn = nn + 1 else nu = nu + 1 end
end
print("udfirst", nn, nu)

-- getmetatable / debug.getmetatable / rawequal through the same guard
-- (a boxed integer has no metatable of its own, io.stdout has one).
local gm, dm, ge = 0, 0, 0
for i = 1, 400 do
  local v = tv2[(i % 8) + 1]
  if getmetatable(v) == nil then gm = gm + 1 end
  if debug.getmetatable(v) == nil then dm = dm + 1 end
  if rawequal(v, B) then ge = ge + 1 end
end
print("getmetatable", gm, dm, "rawequal", ge)

-- Plain == / ~= (BC_ISEQV/ISNEV): (userdata, int64) was recorded as a
-- constant "different" with no guard, so a box passing the userdata load
-- guard compared unequal to its own value. Both orders, slot vs slot, slot
-- vs upvalue, and other userdata kinds (newproxy is LuaJIT-only; PUC gets
-- a second io handle, the counts are the same).
local ud2 = newproxy and newproxy(true) or io.stderr
local ud3 = newproxy and newproxy() or io.stdin
local function eqloop(tab, w)
  local eq, ne, eqr, ner = 0, 0, 0, 0
  for i = 1, 400 do
    local v = tab[(i % 8) + 1]
    if v == w then eq = eq + 1 end
    if v ~= w then ne = ne + 1 end
    if w == v then eqr = eqr + 1 end
    if w ~= v then ner = ner + 1 end
  end
  return eq, ne, eqr, ner
end
print("eq-stdout", eqloop({ ud, ud, ud, ud, B, B, B, B }, B))
print("eq-proxy", eqloop({ ud2, ud2, ud2, ud2, B, B, B, B }, B))
print("eq-proxy2", eqloop({ ud3, ud3, ud3, ud3, B, B, B, B }, B))
print("eq-widened", eqloop({ ud, ud, ud, ud, W, W, W, W }, W))
local function equp()  -- the int64 as an upvalue, the userdata in a slot
  local eq, ne = 0, 0
  local tab = { ud, ud, ud, ud, B, B, B, B }
  for i = 1, 400 do
    local v = tab[(i % 8) + 1]
    if v == B then eq = eq + 1 end
    if B ~= v then ne = ne + 1 end
  end
  return eq, ne
end
print("eq-upvalue", equp())
local function eqfloat()  -- an integral float constant equals the boxed integer
  local eq = 0
  local tab = { ud, ud, ud, ud, B, B, B, B }
  for i = 1, 400 do
    local v = tab[(i % 8) + 1]
    if v == 1125899906842627.0 then eq = eq + 1 end
  end
  return eq
end
print("eq-float", eqfloat())
