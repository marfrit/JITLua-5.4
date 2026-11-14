--! §4.1 math library 5.4 split; §4.2 os.time/os.date/os.difftime (harness sets TZ=UTC)
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("constants", math.maxinteger, math.mininteger, math.pi, math.huge, math.maxinteger)
p("type tointeger ult", type(math.type), type(math.tointeger), type(math.ult))
p("ult", math.ult(1, 2), math.ult(-1, 2), math.ult(math.mininteger, math.maxinteger))
p("abs", math.abs(-3), math.type(math.abs(-3)), math.abs(-3.0), math.type(math.abs(-3.0)),
  math.abs(math.mininteger))
p("max min mixed", math.max(1, 2.0), math.type(math.max(1, 2.0)), math.min(1.0, 2),
  math.type(math.min(1.0, 2)), math.max(1, 2, 3), math.min(-1, -2.5))
p("floor ceil trunc", math.floor(3.7), math.ceil(3.2), math.type(math.floor(3.7)),
  math.floor(-3.7), math.ceil(-3.2), math.floor(3), math.type(math.floor(3)))
p("fmod", math.fmod(5, 3), math.fmod(-5, 3), math.fmod(5.5, 2), math.type(math.fmod(5, 3)))
p("modf", math.modf(3.7), math.modf(-3.7))
p("sqrt pow", math.sqrt(16), math.type(math.sqrt(16)), math.sqrt(-1), math.pow == nil)
p("exp log", math.log(8, 2), math.log(0), math.exp(1e6))
p("trig", math.sin(0), math.cos(0), math.atan(1), math.atan2 == nil, math.atan(1, 1))
p("deg rad", math.deg(math.pi), math.rad(180))
p("random seeded", (function() math.randomseed(42) return math.random(), math.random(1, 10), math.random(10) end)())
p("random bounds", (function()
  math.randomseed(7)
  local lo, hi = 1, 0
  for i = 1, 200 do local v = math.random(5, 9) if v < 5 or v > 9 then return "OUT" end lo = math.min(lo, v) hi = math.max(hi, v) end
  return lo, hi, math.type(math.random(5, 9))
end)())
p("random err", pcall(math.random, 0), pcall(math.random, 5, 1), pcall(math.random, 1, 2 ^ 62))
p("randomseed err", pcall(math.randomseed, 1, 2))
p("os.time table", os.time({ year = 2000, month = 1, day = 1, hour = 12, min = 0, sec = 0, isdst = false }))
p("os.date utc", os.date("!%Y-%m-%dT%H:%M:%S", 946728000))
p("os.date fields", (function()
  local t = os.date("!*t", 946728000)
  return t.year, t.month, t.day, t.hour, t.min, t.sec, t.wday, t.yday, tostring(t.isdst)
end)())
p("os.date roundtrip", os.time(os.date("!*t", 946728000)))
p("os.difftime", os.difftime(100, 50), math.type(os.difftime(100, 50)))
p("os.time err", pcall(os.time, { year = 2000 }), pcall(os.time, { year = 2000, month = 13, day = 1 }))
p("os.clock", type(os.clock()))
