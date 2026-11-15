--! §4.1 boxed 64-bit integers (ADR-001b step 1): the exact bounds must display,
--! type as integers, format with %d/%x/%s and work as table keys -- in the
--! interpreter and the JIT. Arithmetic on them (wrap, //, bitwise) still needs
--! step 3, so this file covers only what step 1 provides.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("values", math.maxinteger, math.mininteger)
p("literal", 0xcbf29ce484222325, math.type(0xcbf29ce484222325),
  9223372036854775807, math.type(9223372036854775807),
  9223372036854775808, math.type(9223372036854775808))
p("literal ops", 0x100000001b3 & 0xffff, 9223372036854775807 // 1)
p("math.type", math.type(math.maxinteger), math.type(math.mininteger))
--! NOTE: math.maxinteger + 0.0 (int64 mixed arithmetic) is step 3, not here.
p("tostring", tostring(math.maxinteger), tostring(math.mininteger))
p("format", string.format("%d", math.maxinteger),
  string.format("%d", math.mininteger), string.format("%x", math.maxinteger),
  string.format("%s", math.mininteger), string.format("%g", 9.2233720368548e+18))
p("equality", rawequal(math.maxinteger, math.maxinteger),
  math.maxinteger == math.maxinteger, 1 == math.maxinteger)
p("table key", (function()
  local t = {}
  t[math.maxinteger] = "max"
  return t[math.maxinteger], t[math.mininteger] == nil
end)())
-- Hot loop: the JIT must agree with the interpreter on all of the above.
local r1, r2, r3, r4
for i = 1, 400 do
  r1 = tostring(math.maxinteger)
  r2 = string.format("%d", math.maxinteger)
  r3 = math.type(math.mininteger)
  r4 = rawequal(math.maxinteger, math.maxinteger)
end
p("jit", r1, r2, r3, r4)
for i = 1, 400 do
  local t = {}
  t[math.maxinteger] = i
  r1 = t[math.maxinteger]
end
p("jit key", r1)
