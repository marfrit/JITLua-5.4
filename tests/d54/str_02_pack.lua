--! §4.2 string.pack/unpack/packsize (5.3+ syntax, 5.4 exactness)
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function pk(fmt, ...) local ok, a, b = pcall(string.pack, fmt, ...) return ok, ok and hex(a) or a end
p("ints", pk("<i4", 7), pk(">i4", 7), pk("i4", 7), pk("<I8", 7), pk("b", -1), pk("B", 255))
p("int widths", pk("i1", -1), pk("i2", -2), pk("i8", -3), pk("j", 1), pk("J", 1), pk("l", 1), pk("L", 1))
p("floats", pk("<f", 1.5), pk("<d", 1.5), pk(">d", 1.5), pk("n", 1.5))
p("strings", pk("z", "ab"), pk("s", "ab"), pk("<s4", "ab"), pk("c3", "ab"), pk("c0", "abc"))
p("align", pk("<!4i4", 1), pk("!1>x", 0), pk(" x i1", 1))
p("size", string.packsize("i4"), string.packsize("<i8"), string.packsize("z") == nil)
p("size err", pcall(string.packsize, "z"), pcall(string.packsize, "s"), pcall(string.packsize, "c0"))
p("unpack", string.unpack("<i4", string.pack("<i4", -12345)))
p("unpack z", string.unpack("z", "ab\0cd"))
p("unpack s", string.unpack("s", "\2ab"))
p("unpack pos", string.unpack("<i2i2", string.pack("<i2i2", 1, 2), 3))
p("unpack multi", string.unpack("<i4f", string.pack("<i4f", 7, 1.5)))
p("unpack err", pcall(string.unpack, "i4", "ab"), pcall(string.unpack, "z", "abc"))
p("pack err", pcall(string.pack, "i4", 2 ^ 31), pcall(string.pack, "b", 128),
  pcall(string.pack, "q", 1), pcall(string.pack, "i17", 1))
p("roundtrip", (function()
  local v = { 1, -2, 3.5, "x", 2 ^ 40 }
  local s = string.pack("<i4i4ds1j", v[1], v[2], v[3], v[4], v[5])
  local a, b, c, d, e = string.unpack("<i4i4ds1j", s)
  return a, b, c, d, e
end)())
