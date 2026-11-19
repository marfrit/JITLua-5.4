--! §6.4 A __tostring that appears in a basic type's metatable after the
--! conversion was already hot must be seen by the next conversion: by
--! tostring() and string.format("%s") in the interpreter and in compiled
--! code, for strings (the string metatable always exists), numbers, booleans
--! and nil. string.format("%s") calls the method for a string argument too
--! (luaL_tolstring); "%q" does not. Output goes through io.write, which never
--! calls __tostring, so the report cannot hide a missed call.
local w = io.write
local function line(label, ...)
  w(label)
  for i = 1, select("#", ...) do w(" ", (select(i, ...))) end
  w("\n")
end
local smt = getmetatable("")
local out = {}

-- 1. tostring(string): the method is installed in iteration 300 of a hot loop.
local function conv(v) return tostring(v) end
for i = 1, 400 do
  if i == 300 then rawset(smt, "__tostring", function() return "S" end) end
  out[i] = conv("a")
end
rawset(smt, "__tostring", nil)
line("tostring string", out[1], out[299], out[300], out[400])

-- 2. string.format("%s", string), same shape; then the plain forms.
for i = 1, 400 do
  if i == 300 then rawset(smt, "__tostring", function() return "S" end) end
  out[i] = string.format("%s", "a")
end
line("format string", out[1], out[299], out[300], out[400])
line("format forms", string.format("[%s|%5s|%-5s|%.1s|%q]", "ab", "ab", "ab", "ab", "ab"),
     ("%s%s"):format("x", "y"))
rawset(smt, "__tostring", function() return 42 end)
line("format number result", string.format("%s|%5s", "a", "a"))
rawset(smt, "__tostring", function() return {} end)
local ok, err = pcall(string.format, "%s", "a")
rawset(smt, "__tostring", nil)
line("format bad result", (ok and "no error" or err:gsub("^.-:%d+: ", "")))
line("format plain again", string.format("%s|%5s", "a", "a"))

-- 3. Numbers: an existing number metatable gets the method later.
local nmt = {}
debug.setmetatable(0, nmt)
for i = 1, 400 do
  if i == 300 then rawset(nmt, "__tostring", function() return "N" end) end
  out[i] = conv(i)
end
line("tostring integer", out[1], out[299], out[300], out[400])
rawset(nmt, "__tostring", nil)
for i = 1, 400 do
  if i == 300 then rawset(nmt, "__tostring", function() return "F" end) end
  out[i] = conv(i + 0.5)
end
line("tostring float", out[1], out[299], out[300], out[400])
line("tostring maxinteger", tostring(math.maxinteger), tostring(math.mininteger))
line("format number", string.format("%s|%s|%d", 7, 7.5, 7))
debug.setmetatable(0, nil)
line("number plain", tostring(7), tostring(7.5))

-- 4. Booleans and nil.
local bmt = {}
debug.setmetatable(true, bmt)
for i = 1, 400 do
  if i == 300 then rawset(bmt, "__tostring", function() return "B" end) end
  out[i] = conv(i % 2 == 0)
end
debug.setmetatable(true, nil)
line("tostring boolean", out[1], out[299], out[300], out[400])
local lmt = {}
debug.setmetatable(nil, lmt)
for i = 1, 400 do
  if i == 300 then rawset(lmt, "__tostring", function() return "NIL" end) end
  out[i] = conv(nil)
end
debug.setmetatable(nil, nil)
line("tostring nil", out[1], out[299], out[300], out[400])

-- 5. The method is stored by compiled code: a function that became hot on
-- other tables stores "__tostring" into the string metatable.
local f = function() return "X" end
local function set(t, v) t.__tostring = v end
local ts = {}
for i = 1, 300 do ts[i] = { x = 1 } end
ts[300] = smt
w("stored before ", tostring("a"), "\n")
for i = 1, 300 do set(ts[i], f) end
local r1, r2 = tostring("a"), string.format("%s", "a")
smt.__tostring = nil
line("stored by a hot function", r1, r2)
line("removed", tostring("a"), string.format("%s", "a"))
