--! §4.2 string.format 5.4 rules + float rendering (tostring/%g use %.14g in
--! 5.4.7 -- NOT shortest-round-trip; MISSION 4.2 claim corrected by experiment).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function f(fmt, ...) return (pcall(string.format, fmt, ...)) end
p("d int", f("%d", 42), f("%5d|", 42), f("%-5d|", 42), f("%+d", 42), f("%05d", 42))
p("d float ok", f("%d", 3.0), f("%d", -0.0), f("%d", 1e18))
p("d float bad", f("%d", 3.5), f("%d", 1e30), f("%d", math.huge))
p("d overflow", f("%d", math.maxinteger), f("%d", math.mininteger))
p("x o i", f("%x", 255), f("%X", 255), f("%o", 8), f("%i", -3), f("%x", 255.0), f("%x", 3.5))
p("u", f("%u", 42))
p("a", f("%a", 1.5), f("%a", 0.1), f("%A", 255.0), f("%a", 0.0))
p("g", f("%g", 0.1), f("%g", 1 / 3), f("%g", 1e16), f("%g", 1e-5), f("%.17g", 0.1),
  f("%.3g", 1234.5), f("%G", 1e20))
p("f e", f("%f", 1.5), f("%.2f", 1.005), f("%e", 1234.5), f("%.0f", 2.5), f("%.0f", 3.5))
p("s q", f("%s", "x"), f("%5s|", "x"), f("%.2s", "abc"), f("%q", 'a"b\\c\nd\0e'),
  f("%q", 3), f("%q", 3.0), f("%q", true), f("%q", nil))
p("c percent", f("%c", 65), f("%%"), f("%5.2f|", 1.5))
p("tostring floats", tostring(0.1 + 0.2), tostring(1 / 3), tostring(2 ^ 53),
  tostring(1e15), tostring(1e16), tostring(123456789.123456789), tostring(1e300),
  tostring(1e-300), tostring(math.huge), tostring(-math.huge))
p("nan canonical", (tostring(0 / 0):gsub("^%-?", "")))
p("format argcount", f("%d %d", 1), f("%d", 1, 2))
p("format bad", f("%y", 1), f("%d", "3"), f("%d", {}))
p("number2str int", tostring(math.maxinteger), tostring(math.mininteger))
