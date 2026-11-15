--! §4.2 string.format %q literal forms (5.4: numbers, nil, booleans).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function q(v) return (pcall(string.format, "%q", v)) end
p("int", q(3), q(-3), q(0))
p("float", q(3.0), q(0.5), q(-0.0), q(1e100))
p("special", q(1/0), q(-1/0), q(0/0))
p("bool nil", q(true), q(false), q(nil))
p("string", q('a"b\\c\nd\0e\255'))
p("no literal", q({}), q(print), q(setmetatable({}, {})))
-- Round-trip: the literal must load back to the same value.
local function rt(v)
  local lit = string.format("%q", v)
  local f = assert(load("return " .. lit))
  local r = f()
  return r == v, math.type(r) == math.type(v)
end
p("roundtrip", rt(3), rt(3.0), rt(0.1), rt(-0.0), rt(1e300), rt(1e-300))
p("roundtrip str", rt('a"b\\c\nd\0e\255'), rt(""))
-- Hot loop: the JIT must produce the same literals.
local acc
for i = 1, 400 do
  acc = string.format("%q|%q|%q|%q", 7, 7.0, true, nil)
end
p("jit", acc)
for i = 1, 400 do acc = string.format("%q", 0.1) end
p("jit float", acc)
