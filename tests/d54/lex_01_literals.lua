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
                     -- INT64 boundary: INT64_MAX-1, INT64_MIN+1
                     "9223372036854775806", "-9223372036854775807",
                     -- INT64 boundary: INT64_MAX, INT64_MIN (via hex)
                     "0x7FFFFFFFFFFFFFFF", "0x8000000000000000",
                     -- Overflow beyond int64
                     "9223372036854775807", "9223372036854775808",
                     "-9223372036854775808", "18446744073709551616",
                     -- Large hex (beyond 32-bit, still int64)
                     "0x100000000", "0x1000000000", "0x10000000000",
                     -- Negative literals
                     "-1", "-0", "-1.0", "-0x10", "-.5", "-1e10",
                     -- Hex floats
                     "0X1p0", "0x0p0",
                     -- Float zero forms
                     "0.0", "0e0", "0E0",
                     -- Known-bad: 5.4 rejects these (fix in parallel)
                     "1_000", "0b1010", "0o17",
                     -- Malformed numbers
                     "1e", "0x", "1.2.3", "0x1p", "1e999", "1e-999",
                     -- UINT64_MAX wraps to INT64_MIN
                     "0xFFFFFFFFFFFFFFFF" }) do
  p("lit", s, lit(s))
end
p("tonumber", tonumber("10"), tonumber("10", 2), tonumber("z", 36), tonumber("0x10"),
  tonumber("0X1p4"), tonumber("  12  "), tonumber("1e2"), tonumber(".5"), tonumber("1."),
  tonumber("08"), tonumber("1_000"), tonumber("0b101"), tonumber(""), tonumber("abc"),
  tonumber("12abc"), tonumber("+3"), tonumber("-0"), tonumber("0x10", 16),
  -- tonumber with invalid strings
  tonumber("0x"), tonumber("0X"), tonumber("1e"), tonumber(nil),
  -- tonumber with various bases
  tonumber("ff", 16), tonumber("FF", 16), tonumber("10", 2), tonumber("10", 8),
  tonumber("10", 36),
  -- tonumber with nil base (defaults to 10)
  tonumber("10", nil))
p("tonumber types", math.type(tonumber("3")), math.type(tonumber("3.0")),
  math.type(tonumber("0x10")), math.type(tonumber("1e2")),
  math.type(tonumber("0x100000000")),
  math.type(tonumber("9223372036854775806")),
  math.type(tonumber("0x7FFFFFFFFFFFFFFF")))
p("tonumber obj", tonumber(setmetatable({}, { __tostring = function() return "7" end })))
-- Stock LuaJIT C-function errors carry no caller location; PUC does.
-- Normalize the location prefix so both sides print the same wording.
local function errpair(f)
  local ok, e = pcall(f)
  return ok, ok or (e:gsub("^.-:%d+: ", ""))
end
p("tonumber base err", errpair(function() return tonumber("1", 1) end),
  errpair(function() return tonumber("1", 37) end))
p("tostring num", tostring(12), tostring(12.0), tostring(1e100), tostring(-0.0))
