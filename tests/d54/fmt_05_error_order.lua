--! §2.4 string.format error order (PUC lstrlib.c str_format): a missing
--! argument is reported ("no value") before the conversion is parsed; for
--! d i u o x X e E f g G the argument is checked before the specification,
--! for c a A p the specification first; a format that ends after '%' or
--! after flags/width is "invalid conversion '%5' to 'format'". %c casts the
--! integer to int as PUC does (2^32+65 is 'A'); this tree saturated it.
--! Printed: errors and results, also from a loop compiled under -jon.
local function e(...)
  local ok, m = pcall(string.format, ...)
  print(ok, (tostring(m):gsub("^[^:]*:%d+: ", "")))
end
e("%d")
e("%5")
e("%")
e("x%5")
e("%5", 1)
e("%", 1)
e("%-")
e("%.")
e("%#d", {})
e("%#d", 1.5)
e("%#d", "1")
e("%010d", "x")
e("%.3c", {})
e("%5.3c", 65)
e("%#x", "x")
e("%#X", {})
e("% o", {})
e("%#u", {})
e("%#a", {})
e("% f", {})
e("%#e", {})
e("%-#g", {})
e("%#G", 1)
e("%#p", 1)
e("% p", {})
e("%5q", 1)
e("%5q")
e("%0000000000000000000000000000d", 1)
e("%0000000000000000000000000000d")
e("%d %d", 1)
e("%y", 1)
e("%y")
for _, v in ipairs({2^32 + 65, 2^32 + 66.0, -2^32 + 67, 65 - 2^40, 0x7fffffff00000044, 1.5}) do
  e("%c", v)
  e("%3c", v)
end
local s = {}
for i = 1, 100 do s[#s + 1] = string.format("%c", i >= 80 and (4294967296 + 67) or 66) end
print(s[1], s[100])
s = {}
for i = 1, 100 do s[#s + 1] = string.format("%c", i >= 80 and (4294967296.0 + 68) or 66.0) end
print(s[1], s[100])
local bad = 0
for i = 1, 100 do if not pcall(string.format, "%c", i >= 80 and 66.5 or 66) then bad = bad + 1 end end
print("c bad", bad)
bad = 0
for i = 1, 100 do if not pcall(string.format, "%d", i >= 90 and 1.5 or 1.0) then bad = bad + 1 end end
print("d bad", bad)
