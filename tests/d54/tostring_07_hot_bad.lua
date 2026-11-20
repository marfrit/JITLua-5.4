--! §5.4 __tostring result check with a compiled trace: the metamethod returns
--! a string while the trace is hot and a non-string only later, so the error
--! must arrive at the right iteration (and only after the trace ran). Mode A
--! compares with PUC 5.4.9, mode B the trace with the interpreter. Also checks
--! a legal number result, a metamethod whose result comes from a table field
--! (the trace cannot know its type), and that a raise inside __tostring is not
--! reported as the result-check error.
local function nometa(s) return (tostring(s):gsub("^.-:%d+: ", "")) end

-- 1. non-string only after the trace compiled: string for i<1000, table at 1000
local n = 0
local o = setmetatable({}, { __tostring = function()
  n = n + 1
  if n == 1000 then return {} end
  return "abc"
end })
local ok, err = pcall(function()
  local a = 0
  for i = 1, 2000 do a = a + #tostring(o) end
  return a
end)
print("late-bad", ok, nometa(err), "calls", n)

-- 2. same, but the bad result is a boolean (not a number, which is legal)
n = 0
local o2 = setmetatable({}, { __tostring = function()
  n = n + 1
  if n == 1200 then return false end
  return tostring(n)
end })
local ok2, err2 = pcall(function()
  local a = 0
  for i = 1, 2000 do a = a + #tostring(o2) end
  return a
end)
print("late-bad-bool", ok2, nometa(err2), "calls", n)

-- 3. legal number result: converted with the 5.4 number format
local f = setmetatable({}, { __tostring = function() return 123456789012345 end })
local g = setmetatable({}, { __tostring = function() return 2.5 end })
local h = setmetatable({}, { __tostring = function() return -0.0 end })
local s = 0
for i = 1, 1500 do s = s + #tostring(f) + #tostring(g) + #tostring(h) end
print("num-result", s, tostring(f), tostring(g), tostring(h), math.type(0 + #tostring(f)))

-- 4. result read from a table field: type unknown while recording
local box = { v = "xy" }
local t = setmetatable({}, { __tostring = function() return box.v end })
local u = 0
for i = 1, 1500 do u = u + #tostring(t) end
box.v = 7
u = u + #tostring(t)
box.v = {}
local ok3, err3 = pcall(tostring, t)
print("field-result", u, ok3, nometa(err3))

-- 5. the metamethod itself raises: that error, not the result-check one
local e = setmetatable({}, { __tostring = function() error("boom") end })
local ok4, err4 = pcall(tostring, e)
print("mm-raises", ok4, nometa(err4))

-- 6. the result changes type inside one hot loop on one code path (the field
-- is reassigned by the loop, not by a branch in the metamethod): a number is
-- converted from that iteration on, a table raises at exactly its iteration.
local box2 = { v = "xy" }
local t2 = setmetatable({}, { __tostring = function() return box2.v end })
local last, sum = 0, 0
local ok5, err5 = pcall(function()
  for i = 1, 2000 do
    if i == 1400 then box2.v = 12345 elseif i == 1700 then box2.v = {} end
    sum = sum + #tostring(t2)
    last = i
  end
end)
print("field-late-bad", ok5, nometa(err5), "last ok", last, "sum", sum)
