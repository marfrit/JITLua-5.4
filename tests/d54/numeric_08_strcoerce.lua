--! §3.4.3 string -> number coercion follows the Lua numeral rules everywhere a
--! string is used as a number: "inf"/"nan" are not numerals, a hexadecimal
--! integer string is an integer whatever its digits ("0x1e" is 30, not a
--! float with an exponent) and wraps modulo 2^64, and "-0" is the integer 0,
--! so its float value is +0.0. Checked for the arithmetic operators, for
--! library number arguments, and for '/' and '^' in compiled code, where the
--! loop is recorded with one string and then runs with the others.
local mtype = math.type
local function fmt(v)
  local t = mtype(v)
  if t == "float" then
    if v ~= v then return "nan" end
    if v == 0 then return (1 / v < 0) and "-0.0" or "0.0" end
    return string.format("%.17g", v)
  elseif t == "integer" then
    return string.format("%d", v) .. "i"
  end
  return type(v)
end
local function try(f, ...)
  local ok, r = pcall(f, ...)
  return ok and fmt(r) or "ERR"
end
local function row(label, ...)
  local t = { ... }
  for i = 1, #t do t[i] = tostring(t[i]) end
  print(label .. ": " .. table.concat(t, " "))
end

local strs = { "0x1e", "0xE", "0Xe0", "0x1p4", "1e1", "-0", "-00", "-0x0", "-0.0",
  "0xffffffffffffffff", "0x8000000000000000", "0x1ffffffffffffffff",
  "-0xffffffffffffffff", "9223372036854775807", "9223372036854775808",
  "inf", "-inf", "nan", "NaN", " Infinity ", "infinity", "2" }

-- 1. Arithmetic operators, interpreter and (hot) the recorder's punt paths.
local ops = {
  function(s) return s + 0 end, function(s) return 0 - s end,
  function(s) return s * 1 end, function(s) return s % 7 end,
  function(s) return -s end, function(s) return s // 1 end,
  function(s) return s / 1 end, function(s) return 1 / s end,
  function(s) return s ^ 1 end, function(s) return 2 ^ s end,
  function(s) return s + s end, function(s) return s + 0.5 end,
}
for _, s in ipairs(strs) do
  local r = {}
  for i, f in ipairs(ops) do r[i] = try(f, s) end
  row("arith " .. string.format("%q", s), table.unpack(r))
end

-- 2. Library number arguments.
for _, s in ipairs(strs) do
  row("lib " .. string.format("%q", s),
      try(math.sqrt, s), try(math.floor, s), try(math.ceil, s), try(math.abs, s),
      try(math.fmod, s, 7), try(math.tointeger, s), try(math.exp, s),
      try(function(s) return #string.format("%g", s) end, s),
      try(function(s) return #string.format("%d", s) end, s),
      try(function(s) return #string.format("%5.1f", s) end, s))
end

-- 3. '/' and '^' stay compiled for a string operand. One loop per operator is
-- recorded with "2" and then runs with every other string: the compiled
-- conversion must give what the interpreter gives (first and last of the 60
-- runs per string are printed; they differ if only one of them is compiled).
local function hot(e, strs)
  local f = assert(load("local a, out = ...\nlocal function f(s) return " .. e ..
    " end\nfor i = 1, #a do local ok, r = pcall(f, a[i]); out[i] = ok and r or 'ERR' end"))
  local a, out = {}, {}
  for i = 1, 300 do a[i] = "2" end
  for _, s in ipairs(strs) do for i = 1, 60 do a[#a + 1] = s end end
  f(a, out)
  local r = {}
  for k = 1, #strs do
    local first, last = out[300 + (k - 1) * 60 + 1], out[300 + k * 60]
    local x, y = first == "ERR" and "ERR" or fmt(first), last == "ERR" and "ERR" or fmt(last)
    r[k] = x == y and x or (x .. "/" .. y)
  end
  row("hot " .. e, table.unpack(r))
end
for _, e in ipairs{ "s / 1", "1 / s", "s ^ 1", "2 ^ s", "math.sqrt(s)",
		    "math.floor(s)", "math.fmod(s, 7)", "s + 0", "-s", "s % 7",
		    "#string.format('%d', s)" } do
  hot(e, strs)
end

-- 4. A string as an integer argument of a recorded string function: the
-- recorder must neither convert the argument slot itself (the function runs
-- on that slot right after the recorder looked at it) nor take another value
-- than the library does.
local idx = { "-1", "0x3", "-0", " 4 ", "0xffffffffffffffff", "0x1ffffffffffffffff",
  "-0x1", "0xfffffffffffffffe", "3.0", "2" }
local function hotidx(e)
  local f = assert(load("local a, out = ...\nfor i = 1, #a do local s = a[i]; out[i] = " .. e .. " end"))
  local a, out = {}, {}
  for _, s in ipairs(idx) do for i = 1, 150 do a[#a + 1] = s end end
  f(a, out)
  local r = {}
  for k = 1, #idx do
    local v, same = out[(k - 1) * 150 + 1], true
    for i = (k - 1) * 150 + 2, k * 150 do same = same and out[i] == v end
    r[k] = tostring(v) .. (same and "" or "(changes)")
  end
  row("idx " .. e, table.unpack(r))
end
hotidx("('hello'):sub(s)"); hotidx("('hello'):sub(2, s)"); hotidx("('hello'):byte(s)")
hotidx("#('x'):rep(s)"); hotidx("('hello'):find('l', s, true)")
