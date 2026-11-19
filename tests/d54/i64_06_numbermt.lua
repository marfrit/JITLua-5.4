--! §4.1 the number metatable on 5.4 integers (ADR-001b): a boxed int64 (an
--! integer literal above the int32 range, or a runtime value outside the
--! inline 47-bit range) must behave exactly like an inline
--! integer or a float with respect to the number metatable -- getmetatable,
--! debug.getmetatable, __index and method calls, __call, __concat, __len,
--! __newindex, the __lt/__le/__add fallbacks, __eq (which must NOT be called
--! for numbers), __metatable and __tostring. Mode A compares the interpreter
--! with PUC 5.4, mode B the JIT with the interpreter, mode R dump/reload.
local function fmt(v)
  local t = math.type(v)
  if t == "integer" then return string.format("%d", v) end
  if t == "float" then return string.format("%.17g", v) end
  return tostring(v)
end
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = (select(i, ...))
    t[i] = (type(v) == "number" and fmt(v) or tostring(v)) ..
           (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end
local function try(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return r end
  return "error: " .. tostring(r):gsub("^.-:%d+: ", "")
end
local function label(v)
  return fmt(v) .. "/" .. (math.type(v) or type(v))
end

-- Values: inline int32, widened 47-bit inline (both signs, at the 2^47 edge),
-- boxed (both signs, at the 2^47 and 2^63 edges) and floats.
local vals = {
  0, 5, -7,
  1 << 40, -(1 << 40), (1 << 46) - 1, -(1 << 46),
  1 << 47, (1 << 47) + 3, -(1 << 47), 1 << 60, -(1 << 60) - 1,
  (1 << 62) + 12345, math.maxinteger, math.mininteger,
  1.5, -2.75, 0.0, -0.0, math.huge, -math.huge,
}

-- The boxed representation must stay invisible to Lua.
p("type", type(5), type(1 << 40), type(1 << 60), type(1.5),
  math.type(5), math.type(1 << 40), math.type(1 << 60), math.type(1.5))
p("guard", type(1 << 60), type(-(1 << 60) - 1), type(math.mininteger),
  math.type(1 << 60), math.type(-(1 << 60) - 1), math.type(1 << 40),
  string.format("%d", 1 << 60), string.format("%d", -(1 << 60) - 1),
  string.format("%d", math.mininteger), string.format("%d", math.maxinteger))

-- No metatable yet: every value answers nil.
local gm0 = {}
for i, v in ipairs(vals) do gm0[i] = getmetatable(v) == nil end
p("none", gm0[1], gm0[8], gm0[14], gm0[16], gm0[20])

local mt = {}
mt.__index = math
mt.__call = function(self, a, b)
  return "call(" .. fmt(self) .. "," .. tostring(a) .. "," .. tostring(b) .. ")"
end
mt.__concat = function(a, b) return "concat" end
mt.__len = function(self) return 42 end
mt.__newindex = function(self, k, v) return "newindex(" .. fmt(self) .. ")" end
mt.__lt = function(a, b) return "lt" end
mt.__le = function(a, b) return "le" end
mt.__add = function(a, b) return "add(" .. fmt(a) .. ")" end
mt.__eq = function(a, b) return true end
debug.setmetatable(0, mt)

-- One line per value: the whole metatable surface.
for i, v in ipairs(vals) do
  p("v", i, label(v),
    getmetatable(v) == mt, debug.getmetatable(v) == mt,
    type(v.floor), type(v.nope),
    try(function() return v:floor() end),
    try(function() return #v end),
    try(function() return v(1, 2) end),
    try(function() return v .. "x" end),
    try(function() return v < {} end),
    try(function() return v <= {} end),
    try(function() return v + {} end),
    try(function() return v == {} end),
    try(function() return v ~= {} end))
end

-- Literals of every width. The parser boxes an integer literal above the
-- int32 range even when the value fits in 47 bits (ADR-001b lj_parse.c), so a
-- literal must reach the same metatable as a computed value. 0x8000000000000000
-- is the 5.4 spelling of math.mininteger (hex integer literals wrap).
local lits = {
  5, -7, 2147483647, -2147483648, 2147483648, -2147483649,
  35184372088835, -35184372088835,  -- 47-bit literal, = (1 << 45) + 3
  1152921504606846976, -1152921504606846977,  -- 2^60 literal
  9223372036854775807, 0x8000000000000000,  -- 2^63 edges
}
for i, v in ipairs(lits) do
  p("lit", i, label(v), type(v), math.type(v), getmetatable(v) == mt,
    debug.getmetatable(v) == mt, string.format("%d", v),
    try(function() return v:floor() end), try(function() return #v end),
    try(function() return v .. "x" end), try(function() return v < {} end),
    try(function() return v + {} end))
end
-- The same literals in a hot loop: the recorder's constant path must agree.
local r
for i = 1, 300 do
  local a = 35184372088835
  local b = 1152921504606846976
  local c = -9223372036854775807
  r = a:floor() + b:floor() + c:floor()
  r = r + #a + #b + #c
  if (a < {}) ~= true then r = r + 1000000 end
  if (b + {}) ~= ("add(" .. fmt(b) .. ")") then r = r + 1000000 end
  if (c .. "x") ~= (fmt(c) .. "x") then r = r + 1000000 end
end
p("lit-hot", r)

-- __newindex on the number metatable.
p("newindex", try(function() local t = 1; t.x = 2; return "no" end))
do
  local seen = nil
  mt.__newindex = function(self, k, v) seen = fmt(self) .. "/" .. tostring(k) end
  ;(1 << 60).x = 9
  p("newindex2", seen)
  mt.__newindex = function(self, k, v) return "newindex(" .. fmt(self) .. ")" end
end

-- Hot loops: the recorder must see the metamethod paths (and agree with -joff).
local acc = 0
for i = 1, 500 do
  local b = (1 << 60) + i
  if getmetatable(b) ~= mt then acc = acc + 1000000 end
  acc = acc + (b:floor() - (1 << 60) - i)
  acc = acc + #b
  if b(1, 2) ~= ("call(" .. fmt(b) .. ",1,2)") then acc = acc + 1000000 end
  if (b < {}) ~= true then acc = acc + 1000000 end
  if (b <= {}) ~= true then acc = acc + 1000000 end
  if (b + {}) ~= ("add(" .. fmt(b) .. ")") then acc = acc + 1000000 end
  if (b == {}) ~= false then acc = acc + 1000000 end
end
p("hot-box", acc)
acc = 0
for i = 1, 500 do
  local w = (1 << 40) + i
  local n = i
  acc = acc + (w:floor() - (1 << 40) - i)
  acc = acc + (n:floor() - i)
  acc = acc + #w + #n
  if (w .. "x") ~= (fmt(w) .. "x") then acc = acc + 1000000 end
  if (n .. "x") ~= (fmt(n) .. "x") then acc = acc + 1000000 end
end
p("hot-inline", acc)
acc = 0
for i = 1, 500 do
  local f = i + 0.5
  acc = acc + (f:floor() - i)
  acc = acc + #f
  if (f .. "x") ~= (fmt(f) .. "x") then acc = acc + 1000000 end
end
p("hot-float", acc)

-- __metatable hides the real table from getmetatable, not from debug.
mt.__metatable = "locked"
p("locked", getmetatable(5), getmetatable(1 << 60), getmetatable(1.5),
  debug.getmetatable(1 << 60) == mt)
mt.__metatable = nil

-- __tostring.
mt.__tostring = function(self) return "TS" end
p("tostring", tostring(5), tostring(1 << 40), tostring(1 << 60),
  tostring(1.5), tostring(math.mininteger))
mt.__tostring = nil

-- The metatable is shared by every number representation; unsetting it via a
-- boxed integer must clear the number slot, not the box's own field.
debug.setmetatable(1 << 60, nil)
p("unset-box", getmetatable(5), getmetatable(1 << 40), getmetatable(1 << 60),
  getmetatable(1.5))

debug.setmetatable(0, mt)
debug.setmetatable(0, nil)
p("unset-num", getmetatable(5), getmetatable(1 << 40), getmetatable(1 << 60),
  getmetatable(1.5))
