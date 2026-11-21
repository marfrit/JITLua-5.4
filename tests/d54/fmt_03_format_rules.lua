--! §6.4.2 string.format: the 5.4.9 conversion rules. lstrlib.c checks each
--! specification (checkformat: allowed flags per conversion, a width that
--! must not start with '0', a precision only where the conversion allows it,
--! at most a two-digit width/precision, a specification shorter than 22
--! characters), rejects '%q' with modifiers, requires a modifier-free %s to
--! be the plain string, and raises "no value" when an argument is missing.
--! The wording is PUC's: "invalid conversion '<spec>' to 'format'",
--! "invalid conversion specification: '<spec>'", "invalid format (too long)",
--! "specifier '%q' cannot have modifiers", "string contains zeros".
local function p(name, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local x = select(i, ...)
    t[i] = tostring(x)
  end
  print(name .. " | " .. table.concat(t, " | "))
end
local function f(fmt, ...) return pcall(string.format, fmt, ...) end

local long = string.rep("0", 600)
p("bad spec", f("%100.3d", 10), f("%1.100d", 10), f("%1" .. long .. ".3d", 10),
  f("%" .. long .. "d", 10))
p("bad flags", f("%010c", 10), f("%.10c", 10), f("%0.34s", 10),
  f("%#i", 10), f("%0.s", 10), f("%-+ #0d", 10))
p("bad conversion", f("%t", 10), f("%F", 10), f("%y", 10))
p("%p modifiers", f("%3.1p", {}), f("%+p", {}), f("%#p", {}),
  f("%.3p", {}), f("-p", {}):sub(1, 2))
p("q modifiers", f("%10q", 10), f("%-q", 10), f("%.1q", 10), f("%q", 10))
p("missing arg", f("%d %d", 1), f("%s %s", "a"))
p("s zeros", f("%10s", "a\0b"), f("%.10s", "\0"), f("%s", "a\0b"),
  f("%-100s", "a\0b"), f("%100s", "a\0b"))
p("s long", #string.format("%99s", "x"), #string.format("%.99s", "x"),
  f("%99s", string.rep("x", 100)), f("%99.5s", string.rep("x", 40)))
print("ok")
