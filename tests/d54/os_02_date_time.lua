-- os.date/os.time 5.4 exactness: field normalization, field errors, *t table,
-- conversion-specifier validation, difftime types. Deterministic and TZ-stable
-- (uses UTC dates and table round-trips only).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local t = { year = 2020, month = 13, day = 32, hour = 25, min = 61, sec = 61 }
local epoch = os.time(t)
p("normalized", t.year, t.month, t.day, t.hour, t.min, t.sec,
  math.type(epoch))
local d = os.date("*t", epoch)
p("table fields", d.year, d.month, d.day, d.hour, d.min, d.sec,
  type(d.wday), type(d.yday), type(d.isdst))
p("utc date", os.date("!%Y-%m-%d %H:%M:%S", 1600000000))
p("empty fmt", os.date("", 1600000000) == "")
p("strftime", os.date("!%Y|%m|%d|%H|%M|%S|%%", 1600000000))
p("field errors", pcall(os.time, { year = 2020, sec = 1.5 }),
  pcall(os.time, { month = 1 }),
  pcall(os.time, { year = 2020, hour = "6" }))
p("date spec errors", pcall(os.date, "%Q"),
  pcall(os.date, "%E"), pcall(os.date, "%"))
p("difftime", os.difftime(1600000100, 1600000000),
  math.type(os.difftime(1600000100, 1600000000)))
p("time integer", math.type(os.time({ year = 2020, month = 1, day = 1 })))
p("time no args", math.type(os.time()))
p("isdst absent", os.date("*t", 0).isdst == nil or
  os.date("*t", 0).isdst == true or os.date("*t", 0).isdst == false)
