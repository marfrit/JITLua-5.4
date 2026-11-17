--! §4.1 bitwise & | ~ << >> : integer semantics, logical >>, negative counts
-- 5.4-only syntax (unported 2.1 fails at parse time).
-- Verified against PUC 5.4.9: floats with an exact integer representation ARE
-- accepted; negative shift counts reverse direction (they do NOT error).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("and/or/xor", 12 & 10, 12 | 10, 12 ~ 10, ~0, ~1)
p("shifts", 1 << 4, 256 >> 4, 1 << 63, 1 << 64, 1 >> 64, -1 >> 1)
p("neg count", 1 << -1, 255 >> -2, 1 >> -63)
p("types", math.type(12 & 10), math.type(1 << 4), math.type(~0))
p("float exact ok", 3.0 & 1, 8.0 >> 1, math.type(3.0 & 1))
p("float inexact", pcall(function() return 3.5 & 1 end))
p("float huge", pcall(function() return 1e30 & 1 end))
p("string operand", pcall(function() return "3" & 1 end))
p("precedence", 1 | 2 & 3, 1 & 2 == 0, 1 << 2 + 1, ~1 & 3)
p("cmp vs bits", (1 & 2) < (1 | 2), 1 < 2 & 3)
p("minint bits", math.mininteger & -1, math.mininteger >> 63, math.maxinteger | 0)
p("wrap shifts", -1 << 63, -1 << 64, 3 << 62)
p("bnot mm", pcall(function() return ~setmetatable({}, {}) end))
assert(1 << 64 == 0 and -1 >> 1 == math.maxinteger, "shifts are mod 64, >> is logical")
assert(1 << -1 == 0 and 255 >> -2 == 1020, "negative count reverses direction")
