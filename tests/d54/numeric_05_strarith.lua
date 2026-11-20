--! §4.1 string coercion in arithmetic: the JIT (hot-looped) must give the
-- same number subtype and value as PUC 5.4 (integer strings stay integer).
-- Parseable by Lua 5.1.

local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local N = 4000

-- Hot-loop f so the JIT compiles the single-op body (mode B), then return the
-- last result. pcall keeps the non-numeric cases from aborting the test.
local function hot(f)
  local ok, r = pcall(function()
    local rr
    for i = 1, N do rr = f() end
    return rr
  end)
  return ok, r
end

local function case(tag, f)
  local ok, r = hot(f)
  if ok then
    p(tag, r, math.type(r) or "nil")
  else
    p(tag, "ERR")
  end
end

local strings = { "2", "2.0", " 2 ", "0x10", "1e2", "-3",
                  "9007199254740993", "9223372036854775807" }

for _, s in ipairs(strings) do
  local ss = s
  case("left  " .. s .. " + 5", function() return ss + 5 end)
  case("left  " .. s .. " - 5", function() return ss - 5 end)
  case("left  " .. s .. " * 5", function() return ss * 5 end)
  case("left  " .. s .. " / 5", function() return ss / 5 end)
  case("left  " .. s .. " // 5", function() return ss // 5 end)
  case("left  " .. s .. " % 5", function() return ss % 5 end)
  case("left  " .. s .. " ^ 5", function() return ss ^ 5 end)
  case("left  -" .. s, function() return -ss end)
  case("right 5 + " .. s, function() return 5 + ss end)
  case("right 5 - " .. s, function() return 5 - ss end)
  case("right 5 * " .. s, function() return 5 * ss end)
  case("right 5 / " .. s, function() return 5 / ss end)
  case("right 5 // " .. s, function() return 5 // ss end)
  case("right 5 % " .. s, function() return 5 % ss end)
  case("right 5 ^ " .. s, function() return 5 ^ ss end)
end

-- Non-numeric string: must raise in every mode (PUC error).
local x = "x"
case("left  x + 5", function() return x + 5 end)
case("right 5 + x", function() return 5 + x end)
-- Bitwise ops on strings raise in PUC 5.4 (no coercion).
case("left  x & 5", function() return x & 5 end)

-- Reverse case: the hot loop is recorded while ss holds a FLOAT-form string
-- ("2.0"), then the same slot holds integer strings. A traced float path
-- would commit to a float (and lose precision above 2^53) where PUC gives
-- an integer; the trace must not exist or must exit.
do
  local ss = "2.0"
  local f = function() return 5 + ss end
  case("rev rec=2.0 run=2.0", f)
  ss = "2"
  case("rev rec=2.0 run=2", f)
  ss = "9007199254740993"
  case("rev rec=2.0 run=2^53+1", f)
end
