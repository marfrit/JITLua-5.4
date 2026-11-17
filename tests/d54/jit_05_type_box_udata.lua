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
