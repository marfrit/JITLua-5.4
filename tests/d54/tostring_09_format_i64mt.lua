--! §6.4 string.format("%s") with a 5.4 integer outside int32 honours a
--! __tostring in the number metatable, in the interpreter and in compiled
--! code: present from the start, and installed after the loop is hot. Output
--! goes through io.write, which never calls __tostring.
local w = io.write
local big = 1 << 40
local nmt = {}
debug.setmetatable(0, nmt)
local out = {}

-- 1. The method appears in iteration 300 of a hot loop.
for i = 1, 400 do
  if i == 300 then rawset(nmt, "__tostring", function() return "N" end) end
  out[i] = string.format("%s", big + i)
end
w("late ", out[1], " ", out[299], " ", out[300], " ", out[400], "\n")

-- 2. The method is there from the start: int64, int32 and float arguments.
local a, b, c
for i = 1, 400 do
  a = string.format("%s", big + i)
  b = string.format("%s", i)
  c = string.format("%s", i + 0.5)
end
w("present ", a, " ", b, " ", c, " ", string.format("%s|%5s|%d", big, big, big), "\n")

-- 3. A number result is legal and converted; removing the method restores
-- the plain conversion in the same loop.
rawset(nmt, "__tostring", function() return 7 end)
for i = 1, 400 do
  if i == 300 then rawset(nmt, "__tostring", nil) end
  out[i] = string.format("%s", big + i)
end
w("removed ", out[1], " ", out[299], " ", out[300], " ", out[400], "\n")
debug.setmetatable(0, nil)
w("plain ", string.format("%s", big + 1), " ", tostring(big + 1), "\n")
