--! §4.1 literals + tonumber (5.4 grammar). NOTE: Lua 5.4 has NO underscore
--! separators and NO 0b binary literals (MISSION 4.1 was wrong; verified 5.4.7).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function lit(s)
  local f, err = load("return " .. s)
  if not f then return "PARSE_ERR" end
  local ok, v = pcall(f)
  if not ok then return "RUNTIME_ERR" end
  return tostring(v) .. ":" .. math.type(v)
end
for _, s in ipairs({ "0", "00", "08", "09", "1.", ".5", "1e10", "1E10", "1e-3",
                     "0x10", "0X10", "0xA", "0x.8", "0x1p4", "0x1P-4", "0xA.8p0",
                     "9223372036854775807", "9223372036854775808",
                     "-9223372036854775808", "18446744073709551616",
                     "1_000", "0b1010", "0o17", "1e", "0x", "1.2.3", "1e999",
                     "0x1p", "1e-999", "0xFFFFFFFFFFFFFFFF" }) do
  p("lit", s, lit(s))
end
p("tonumber", tonumber("10"), tonumber("10", 2), tonumber("z", 36), tonumber("0x10"),
  tonumber("0X1p4"), tonumber("  12  "), tonumber("1e2"), tonumber(".5"), tonumber("1."),
  tonumber("08"), tonumber("1_000"), tonumber("0b101"), tonumber(""), tonumber("abc"),
  tonumber("12abc"), tonumber("+3"), tonumber("-0"), tonumber("0x10", 16))
p("tonumber types", math.type(tonumber("3")), math.type(tonumber("3.0")),
  math.type(tonumber("0x10")), math.type(tonumber("1e2")))
p("tonumber obj", tonumber(setmetatable({}, { __tostring = function() return "7" end })))
p("tonumber base err", pcall(function() return tonumber("1", 1) end),
  pcall(function() return tonumber("1", 37) end))
p("tostring num", tostring(12), tostring(12.0), tostring(1e100), tostring(-0.0))
