--! B6: hot tostring conversions. Prints "B6 <case> <ms> <checksum>" per case.
--! Cases: num = tostring(integer), str = tostring of a literal string, obj =
--! tostring of a table whose __tostring returns a string. Run the same script
--! against two builds and interleave them: the no-metamethod cases must stay
--! flat; obj is the case the 5.4 result check costs.
local N = 2000000

local function run(label, f)
  local t0 = os.clock()
  local sum = f(N)
  local ms = (os.clock() - t0) * 1000
  print(string.format("B6 %s %.1f %d", label, ms, sum))
end

run("num", function(n)
  local a = 0
  for i = 1, n do a = a + #tostring(i) end
  return a
end)

run("str", function(n)
  local a, v = 0, "abc"
  for i = 1, n do a = a + #tostring(v) end
  return a
end)

run("obj", function(n)
  local a = 0
  local o = setmetatable({}, { __tostring = function() return "abc" end })
  for i = 1, n do a = a + #tostring(o) end
  return a
end)

run("fmt", function(n)
  local a = 0
  for i = 1, n do a = a + #string.format("%s", i) end
  return a
end)
