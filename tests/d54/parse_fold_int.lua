--! §4.1 parse-time constant folding: an int-op-int result outside int32 must
--! not become a rounded float constant. The runtime integer operation gives
--! the exact boxed 5.4 integer. Covers + - * / // % unary -, shifts, & | ~ and
--! the zero-divisor/error edge cases. Mode A compares with PUC 5.4,
--! B the JIT with the interpreter, R dump/reload.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = select(i, ...)
    t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end
local function ty(v) return math.type(v) end

p("add", 2147483647 + 1)
p("sub", -2147483648 - 1)
p("neg-min", -(-2147483648))
p("mul2", 2147483647 * 2)
p("mul53", 2147483647 * 2147483647)
p("mul53+1", 2147483647 * 2147483647 + 1)
p("div", 7 / 2, 1 / 0)
p("idiv-min", -2147483648 // -1)
p("mod-min", -2147483648 % -1, 2147483647 % 1, -2147483648 % 3)
p("mininteger", math.mininteger // -1, math.mininteger % -1)
p("mod0", pcall(function() return 3 % 0 end))
p("idiv0", pcall(function() return 3 // 0 end))
p("bnot", ~2147483648, ~0, ~2147483647)
p("band", 2147483647 & 2147483648, -2147483648 & 0xff)
p("bor", 2147483647 | 2147483648)
p("bxor", 2147483647 ~ 2147483648)
p("shl", 1 << 40, 1 << 63)
p("shr", -1 >> 1, 256 >> 4)
p("shift-neg", 1 << -1, 1 >> -1)
p("types", ty(1 << 40), ty(~2147483648), ty(2147483647 | 2147483648))
p("zero-sign", 0 * -1, -1 * 0, 0 // -1)
p("mixed-add", 2147483647 + 1.0, 2147483648 + 0)
p("pow", 2 ^ 31, 2 ^ 0)

assert(2147483647 + 1 == 2147483648 and ty(2147483647 + 1) == "integer")
assert(-2147483648 - 1 == -2147483649 and ty(-2147483648 - 1) == "integer")
assert(-(-2147483648) == 2147483648 and ty(-(-2147483648)) == "integer")
assert(2147483647 * 2 == 4294967294 and ty(2147483647 * 2) == "integer")
assert(2147483647 * 2147483647 == 4611686014132420609 and
  ty(2147483647 * 2147483647) == "integer")
assert(2147483647 * 2147483647 + 1 == 4611686014132420610 and
  ty(2147483647 * 2147483647 + 1) == "integer")
assert(7 / 2 == 3.5 and ty(7 / 2) == "float")
assert(1 / 0 == math.huge and ty(1 / 0) == "float")
assert(-2147483648 // -1 == 2147483648 and ty(-2147483648 // -1) == "integer")
assert(-2147483648 % -1 == 0 and ty(-2147483648 % -1) == "integer")
assert(math.mininteger // -1 == math.mininteger and
  ty(math.mininteger // -1) == "integer")
assert(math.mininteger % -1 == 0 and ty(math.mininteger % -1) == "integer")
assert(not pcall(function() return 3 % 0 end))
assert(not pcall(function() return 3 // 0 end))
assert(~2147483648 == -2147483649 and ty(~2147483648) == "integer")
assert(2147483647 & 2147483648 == 0 and ty(2147483647 & 2147483648) == "integer")
assert(2147483647 | 2147483648 == 4294967295 and
  ty(2147483647 | 2147483648) == "integer")
assert(2147483647 ~ 2147483648 == 4294967295 and
  ty(2147483647 ~ 2147483648) == "integer")
assert(1 << 40 == 1099511627776 and ty(1 << 40) == "integer")
assert(1 << 63 == math.mininteger and ty(1 << 63) == "integer")
assert(-1 >> 1 == math.maxinteger and ty(-1 >> 1) == "integer")
assert(1 << -1 == 0 and 1 >> -1 == 2)
assert(0 * -1 == 0 and ty(0 * -1) == "integer")
assert(-1 * 0 == 0 and ty(-1 * 0) == "integer")
assert(0 // -1 == 0 and ty(0 // -1) == "integer")
assert(2147483647 + 1.0 == 2147483648.0 and
  ty(2147483647 + 1.0) == "float")
assert(2147483648 + 0 == 2147483648 and ty(2147483648 + 0) == "integer")
assert(2 ^ 31 == 2147483648.0 and ty(2 ^ 31) == "float")
assert(2 ^ 0 == 1.0 and ty(2 ^ 0) == "float")
