--! §2.4 string.format in compiled code raises what the interpreter raises.
--! %d %i %u %o %x %X need an exact integer (PUC luaL_checkinteger); the
--! recorder converted any float argument with a truncating call, so a loop
--! compiled for 1.0 then returned 0, 1, 2 or -9223372036854775808 for 0.5,
--! inf, nan, 2^63 and -2^63 instead of "number has no integer
--! representation". A loop also runs over the rejected formats ('%', '%10',
--! '%.', '%.100d'), missing arguments and %c. Printed: per format, how many
--! calls failed and the last result or message of each kind.
local function norm(m) return (tostring(m):gsub("^[^:]*:%d+: ", "")) end
local vals = {1.0, 2.0, 3.0, 0.5, 1 / 0, -1 / 0, 0 / 0, 2^63, -2^63, -2^63 - 2048,
              1e300, 3, "4", "4.5", 2^53}
for _, fmt in ipairs({"%d", "%i", "%u", "%o", "%x", "%X", "%5d", "%-3x"}) do
  local out = {}
  for _ = 1, 3 do
    for i = 1, #vals do
      for _ = 1, 30 do
        local ok, r = pcall(string.format, fmt, vals[i])
        out[i] = (ok and "ok " or "err ") .. norm(r)
      end
    end
  end
  print(fmt, table.concat(out, " | "))
end
local fmts = {"%", "%10", "%.", "%.100d", "%-", "%5", "%y", "%#d", "%d"}
for _, fmt in ipairs(fmts) do
  local r1, r2
  for _ = 1, 100 do
    r1 = norm(select(2, pcall(string.format, fmt)))
    r2 = norm(select(2, pcall(string.format, fmt, 1.5)))
  end
  print(fmt, r1, "|", r2)
end
local s
for i = 1, 200 do
  local ok, r = pcall(string.format, "%d:%c", i, i < 150 and 65 or 65.5)
  s = (ok and "ok " or "err ") .. norm(r)
end
print("mixed", s)
