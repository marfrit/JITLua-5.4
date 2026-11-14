--! §4.2 utf8 library (5.3+): char, codes, len, offset, charpattern
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("exists", type(utf8), type(utf8.char), type(utf8.len), type(utf8.offset), type(utf8.codes))
p("charpattern", utf8.charpattern)
p("char", utf8.char(65), utf8.char(0x1F600), utf8.char(0x10FFFF), utf8.char(0, 65))
p("char err", pcall(utf8.char, 0x110000), pcall(utf8.char, -1), pcall(utf8.char, 0xD800))
p("len", utf8.len("hello"), utf8.len("h\233llo"), utf8.len("\240\159\152\128"), utf8.len(""))
p("len invalid", utf8.len("\255"), utf8.len("\192\128"), utf8.len("a\255b"))
p("len range", utf8.len("h\233llo", 2), utf8.len("h\233llo", 1, 2), utf8.len("h\233llo", -1))
p("offset", utf8.offset("h\233llo", 2), utf8.offset("h\233llo", -1), utf8.offset("h\233llo", 1, 3))
p("offset err", pcall(utf8.offset, "h\233llo", 2, 2), utf8.offset("\240\159\152\128", 2))
p("codes", (function()
  local t = {}
  for pos, c in utf8.codes("a\233\240\159\152\128") do t[#t + 1] = pos .. "=" .. c end
  return table.concat(t, ",")
end)())
p("codes invalid", pcall(function()
  for pos, c in utf8.codes("a\255") do end
end))
p("len lax", utf8.len("\237\160\128"), utf8.len("\244\144\128\128"))
p("pattern match", ("h\233llo"):match(utf8.charpattern .. "+") ~= nil)
