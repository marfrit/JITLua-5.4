--! §4.2 luaL_checkinteger: a number (or numeral string) that is not exactly
--! an integer raises "number has no integer representation"; exact integer
--! forms, including exact floats and integer numeral strings, are accepted.
--! Covers the library sites that used to truncate: string.byte/sub/rep/char,
--! %c, select, tonumber base, table.unpack, utf8.char, math.random(seed),
--! collectgarbage step, debug levels. Differential against PUC 5.4.9.
local function norm(e)
  local s = tostring(e)
  s = s:gsub("^.-:%d+: ", "")
  return s
end
local function q(label, f, ...)
  local t = { pcall(f, ...) }
  local ok, a, b = t[1], t[2], t[3]
  local tail
  if ok then
    tail = tostring(a) .. "," .. tostring(b)
  else
    tail = norm(a)
  end
  print(label .. " | ok=" .. tostring(ok) .. " | " .. tail)
end

q("byte 1.5", string.byte, "abc", 1.5)
q("byte 1.0", string.byte, "abc", 1.0)
q("byte '1'", string.byte, "abc", "1")
q("byte '1.5'", string.byte, "abc", "1.5")
q("sub start 1.5", string.sub, "abc", 1.5)
q("sub end 2.5", string.sub, "abc", 1, 2.5)
q("sub end 2.0", string.sub, "abc", 1, 2.0)
q("rep 2.5", string.rep, "x", 2.5)
q("rep 2.0", string.rep, "x", 2.0)
q("rep 1e20", string.rep, "x", 1e20)
q("rep 'abc'", string.rep, "x", "abc")
q("char 65.5", string.char, 65.5)
q("char 65.0", string.char, 65.0)
q("char '65'", string.char, "65")
q("format c 65.5", string.format, "%c", 65.5)
q("format c 65.0", string.format, "%c", 65.0)
q("select 1.5", select, 1.5, "a", "b")
q("select 2.0", select, 2.0, "a", "b")
q("tonumber base 1.5", tonumber, "10", 1.5)
q("tonumber base 16.0", tonumber, "10", 16.0)
q("unpack 1.5", table.unpack, { 1, 2 }, 1.5)
q("unpack 1.0", table.unpack, { 1, 2 }, 1.0)
q("utf8.char 65.5", utf8.char, 65.5)
q("utf8.char 65.0", utf8.char, 65.0)
q("math.random 1.5", math.random, 1.5)
q("math.randomseed 1.5", math.randomseed, 1.5)
q("collectgarbage step 1.5", collectgarbage, "step", 1.5)
q("debug.getlocal level 1.5", debug.getlocal, 1.5, 1)
q("debug.upvaluejoin idx 1.5", debug.upvaluejoin,
  function() local x; return function() return x end end, 1.5,
  function() local y; return function() return y end end, 1)
