---! §6 standard library with 5.4 integers outside int32 (widened and boxed):
---! math.min/max/abs/floor/ceil/fmod/tointeger/ult, string coercion of
---! integer strings ("1152921504606846976" is an integer, "9223372036854775808"
---! a float, hex wraps), `..` concatenation, tonumber, tostring,
---! string.format, string.rep/sub/char/byte with large arguments, and the
---! interpreter's GC on pure int64 arithmetic. Mode A compares with PUC,
---! mode B the JIT with the interpreter.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = (select(i, ...))
    t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end
local function try(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return r end
  return "error: " .. tostring(r):gsub("^.-:%d+: ", "")
end
local w, b = 1 << 40, 1 << 60

-- math.min/max: exact across int64 and float, result keeps the winner.
p("minmax", math.max(b + 1, w), math.max(w + 1, 3), math.min(b + 1, w), math.min(-(b + 1), -w),
  math.max(b, 2.5), math.min(b, 2.5), math.max(2^62, b), math.min(2^62, b + 1),
  math.max(b, b + 0.0), math.min(b + 0.0, b), math.max(math.mininteger, -2^63), math.max(w, w + 0.5))
for i = 1, 300 do  -- hot: int64 args reach the C fallback every time
  local m = math.max(b + i, w + i, i); local n = math.min(b + i, w + i, -i)
  if m ~= b + i or n ~= -i then p("minmax-loop", i, m, n) break end
end
p("minmax-loop", "ok")

-- `..` with widened and boxed values; concat of a float stays a float.
p("concat", (b + 1) .. "", (w + 1) .. "", "x" .. (b + 1) .. "y", 1.5 .. (b + 1), (-(b + 1)) .. "|" .. math.mininteger)
local cs = 0
for i = 1, 200 do cs = cs + #((b + i) .. "/" .. (w + i)) end
p("concat-loop", cs)

-- String coercion: integer syntax keeps integers of any size (5.4 §3.4.3).
p("coerce", "1152921504606846976" + 0, "1099511627776" * 2, "-9223372036854775808" - 0,
  "9223372036854775808" + 0, "0x7fffffffffffffff" + 0, "0xffffffffffffffff" + 0,
  "1152921504606846976" + 1, "10" + 5, "1e2" * 2, " 1152921504606846976 " + 0)
p("tonumber", tonumber("1152921504606846976"), tonumber("1099511627776"), tonumber("-9223372036854775808"),
  tonumber("9223372036854775808"), tonumber("0x7fffffffffffffff"), tonumber("0x10000000000000000"),
  tonumber("7fffffffffffffff", 16), tonumber(b + 1), tonumber(w), tonumber("  -1099511627776  "),
  tonumber("1152921504606846976.0"), tonumber("1e18"))
p("tostring", tostring(b + 1), tostring(w), tostring(math.mininteger), tostring(-w))

-- math with int64 arguments.
p("math", math.abs(math.mininteger), math.abs(-(b + 1)), math.floor(b + 1), math.ceil(w + 1),
  math.floor(2^60), math.fmod(b + 1, 7), math.fmod(-(b + 1), 7), math.fmod(math.mininteger, -1),
  math.fmod(b, 1), math.tointeger("1152921504606846976"), math.tointeger(2^60), math.tointeger(2^63),
  math.ult(-1, b), math.ult(b, -1), math.sqrt(b), math.type(b + 1), math.type(w + 1))
p("fmod-err", try(math.fmod, b, 0), try(math.fmod, 5, 0))
p("random", (function() math.randomseed(7); local r = math.random(b, b + 10); return r >= b and r <= b + 10 end)())

-- string.format with int64 arguments.
p("format", string.format("%d", b + 1), string.format("%x", b + 1), string.format("%5d|%-22d|%022d", w, b, -b),
  string.format("%s", b + 1), string.format("%i", -(w + 1)), string.format("%.1f", b), string.format("%q", b + 1),
  string.format("%q", math.mininteger), string.format("%X", -1), string.format("%o", w), string.format("%d", 2^53),
  string.format("%g", b), string.format("%c", (b + 65) & 0xff), string.format("%5.2s|", b))
p("format-err", try(string.format, "%d", 2^63), try(string.format, "%d", 1.5))
local fs = 0
for i = 1, 200 do fs = fs + #string.format("%d:%x:%s", b + i, w + i, b - i) end
p("format-loop", fs)

-- Library functions that take integer positions/counts with large values.
p("strfuncs", ("hello"):sub(b + 2), ("hello"):sub(-(b + 2), 2), ("hello"):sub(2, b), ("hello"):byte(w + 1),
  #("x"):rep(w & 3), string.char((b + 65) & 0xff), ("hello"):find("l", b), ("hello"):find("l", -(b)),
  select(2, w, b + 1), select(-1, w, b + 1), select("#", b, w), (select(2, table.unpack({w, b + 1}))),
  table.concat({w, b + 1, 3}, ","), (function() local t = {} table.insert(t, b + 1) return t[1] end)())
p("strfuncs-err", try(string.rep, "x", b), try(string.char, b), try(select, b, 1), try(table.insert, {}, b, 1),
  try(string.rep, "x", -(b)))

-- Hot loops for the recorder: tostring/tonumber/format/math with int64 args.
local ts, tn, mf, sq, fm = 0, 0, 0, 0, 0
for i = 1, 300 do
  ts = ts + #tostring(b + i) + #tostring(-(w + i))
  tn = tn + tonumber("1152921504606846976") + tonumber("1099511627776") + (tonumber(b + i) - b)
  mf = mf + math.abs(-(b + i)) - b + math.abs(math.mininteger + i) - b
  sq = sq + math.sqrt(b + i) + math.floor(w + i) - w + math.ceil(b + i) - b
  fm = fm + #string.format("%s|%d|%5d|%x", b + i, -(w + i), w, b + i)
end
p("rec-loops", ts, tn, mf, sq, fm)
local mm1, mm2, mm3 = 0, 0, 0
for i = 1, 300 do
  mm1 = mm1 + math.max(b + i, w, i) - b + math.min(b + i, w, i)
  mm2 = mm2 + math.min(-(b + i), -w) + b + math.max(w + i, -i) - w
  mm3 = mm3 + math.max(i, 5) + math.min(w + i, w + 2) - w  -- narrowing back to int32
end
p("minmax-rec", mm1, mm2, mm3)
local cat = 0
for i = 1, 300 do cat = cat + #(i .. (b + i) .. (w + i) .. 1.5 .. "x") end
p("concat-rec", cat)

-- Interpreter GC on pure int64 arithmetic: memory must stay bounded.
collectgarbage(); collectgarbage()
local x = 0x9e3779b97f4a7c15
for i = 1, 200000 do x = x ~ (x << 13); x = x ~ (x >> 7); x = x ~ (x << 17) end
p("gc-drive", x, collectgarbage("count") < 16384)
