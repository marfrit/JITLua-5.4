--! §5 io library 5.4 exactness, part 2: read formats, lines, seek, setvbuf,
--! type/close/flush, input/output by name, write return values and closed or
--! wrong-mode handles. Differential: JITLua-5.4 vs PUC-Lua 5.4.9 -- the output
--! must be byte-identical (harness modes A/B/R use the same script).
--!
--! Deliberately not covered here, because it needs the 64-bit integer value
--! model (owned by the i64 work): integer numerals outside int32 and the
--! PUC hex-overflow rule ("0xffffffffffffffff" is integer -1 in 5.4, while
--! lj_strscan_number yields a float). Those are tracked in the i64 phase.
--!
--! Error texts are normalised: position prefix stripped, the callee name in
--! "bad argument #N to '...'" replaced by FUNC. Both implementations then
--! agree on the parenthesised reason.

local function normerr(e)
  local s = tostring(e)
  s = s:gsub("^.-:%d+: ", "")
  s = s:gsub("bad argument #(%d+) to '[^']*'", "bad argument #%1 to FUNC")
  return s
end
local function show(v)
  if math.type and math.type(v) then return math.type(v) .. ":" .. tostring(v) end
  return tostring(v)
end
local function count(...) local n = select("#", ...) return n, ... end
local function j(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = show((select(i, ...))) end
  return table.concat(t, ";")
end
local function p(label, ...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = show((select(i, ...))) end
  print(label .. " | n=" .. n .. " | " .. table.concat(t, ","))
end
local function q(label, f)
  local ok, a, b, c, d = pcall(f)
  print(label .. " | ok=" .. tostring(ok) ..
        " | " .. show(a) .. " | " .. show(b) .. " | " .. show(c) .. " | " ..
        show(d))
end
local function qe(label, f)
  local ok, e = pcall(f)
  print(label .. " | ok=" .. tostring(ok) .. " | err=" .. normerr(e))
end
local function tmp(data)
  local f = io.tmpfile()
  if data then f:write(data); f:seek("set", 0) end
  return f
end
local function bytes(s)
  local t = {}
  for i = 1, #s do t[i] = string.byte(s, i) end
  return #s .. ":" .. table.concat(t, ".")
end

-- 1. read formats
print("== read formats ==")
q("num types", function()
  local f = tmp("10 1e2 0x10 3.5 07 -0x10 1.5e-2 3.0 1.0e2 00")
  local out = {}
  for i = 1, 10 do out[i] = show(f:read("n")) end
  f:close()
  return table.concat(out, ";")
end)
q("num stops at non-numeral", function()
  local f = tmp("12abc")
  local a = f:read("n")
  local b = f:read("a")
  f:close()
  return a, b
end)
q("num invalid", function()
  local f = tmp("0xzz")
  local a = f:read("n")
  local b = f:read("a")
  f:close()
  return a, b
end)
q("read a keeps zero bytes", function()
  local f = tmp("a\0b\nc")
  local s = f:read("a")
  f:close()
  return bytes(s)
end)
q("lines l and L", function()
  local f = tmp("one\ntwo\r\n\nlast")
  local a = f:read("l")
  local b = f:read("l")
  local c = f:read("l")
  local d = f:read("l")
  local e = f:read("l")
  f:seek("set", 0)
  local x = f:read("L")
  local y = f:read("L")
  local z = f:read("L")
  f:close()
  return j(a, bytes(b), c, d, e, bytes(x), bytes(y), bytes(z))
end)
q("line keeps zero bytes", function()
  local f = tmp("a\0b\n")
  local s = f:read("l")
  f:close()
  return bytes(s)
end)
q("empty line", function()
  local f = tmp("\n")
  local a = f:read("l")
  f:close()
  return a, a == ""
end)
q("read eof", function() local f = tmp(""); local a, b = f:read("l"); f:close(); return a, b end)
q("multiple formats", function()
  local f = tmp("1 one\n2 two\n")
  local a, b, c = f:read("n", "l", "l")
  local d = f:read("l")
  f:close()
  return a, b, c, d
end)
q("multiple formats stop at failure", function()
  local f = tmp("x\n")
  local a, b, c = f:read("l", "n", "l")
  f:close()
  return a, b, c
end)
qe("numeric string format is invalid", function()
  local f = tmp("abcdef")
  local ok, e = pcall(f.read, f, "2")
  f:close()
  if ok then return e end
  error(e)
end)
qe("numeric string digit format is invalid", function()
  local f = tmp("xyz")
  local ok, e = pcall(f.read, f, "1")
  f:close()
  if ok then return e end
  error(e)
end)
q("read count argument", function()
  local f = tmp("abcdef")
  local a = f:read(3)
  local b = f:read(0)
  local c = f:read(0)
  f:seek("set", 6)
  local d = f:read(0)
  f:close()
  return a, b, c, d
end)
qe("read fractional count", function()
  local f = tmp("abcdef")
  local ok, e = pcall(f.read, f, 1.5)
  f:close()
  if ok then return e end
  error(e)
end)
qe("read boolean format", function()
  local f = tmp("abcdef")
  local ok, e = pcall(f.read, f, true)
  f:close()
  if ok then return e end
  error(e)
end)
q("star prefix", function() local f = tmp("s\n"); local a = f:read("*l"); f:close(); return a end)

-- 2. lines
print("== lines ==")
q("io.lines(filename) results", function()
  local path = os.tmpname()
  local f = io.open(path, "w"); f:write("a\nb\n"); f:close()
  local n, it, st, ctl, tc = count(io.lines(path))
  local t = {}
  for l in it do t[#t + 1] = l end
  os.remove(path)
  return j(n, type(it), show(st), show(ctl), io.type(tc))
end)
q("io.lines formats", function()
  local path = os.tmpname()
  local f = io.open(path, "w"); f:write("1 2\n3 4\n"); f:close()
  local t = {}
  for a, b in io.lines(path, "n", "n") do
    t[#t + 1] = show(a) .. "/" .. show(b)
  end
  os.remove(path)
  return table.concat(t, ",")
end)
q("io.lines closes a named file at eof, with formats", function()
  local path = os.tmpname()
  local f = io.open(path, "w"); f:write("1 2\n3 4\n"); f:close()
  local n, it, st, ctl, tc = count(io.lines(path, "n", "n"))
  local t = {}
  for a, b in it do t[#t + 1] = show(a) .. "/" .. show(b) end
  os.remove(path)
  return io.type(tc), table.concat(t, ",")
end)
q("io.lines() uses io.input", function()
  local f = tmp("p\nq\n")
  local old = io.input()
  io.input(f)
  local n, it = count(io.lines())
  local t = {}
  for l in it do t[#t + 1] = l end
  io.input(old)
  f:close()
  return n, type(it), table.concat(t, ",")
end)
qe("io.lines missing file errors at call time", function()
  local ok, e = pcall(io.lines, "/nonexistent-lj54-io02-file")
  if ok then return e end
  error(e)
end)
q("file:lines formats, handle stays open", function()
  local f = tmp("1 2\n3 4\n")
  local t = {}
  for a, b in f:lines("n", "n") do t[#t + 1] = show(a) .. "/" .. show(b) end
  local pos = f:seek("cur", 0)
  local rest = f:read("a")
  f:close()
  return table.concat(t, ","), pos, rest
end)

-- 3. seek
print("== seek ==")
q("seek modes", function()
  local f = tmp("0123456789")
  local a = f:seek("set", 3)
  local b = f:seek("cur", 2)
  local c = f:seek()
  local d = f:seek("end", -2)
  local e = f:seek("end")
  f:close()
  return j(a, b, c, d, e)
end)
q("seek default offset", function()
  local f = tmp("abc")
  local a = f:seek("set")
  local b = f:seek()
  f:seek("end", -3)
  local s = f:read("a")
  f:close()
  return a, b, s
end)
qe("seek invalid whence", function()
  local f = tmp("x")
  local ok, e = pcall(f.seek, f, "middle")
  f:close()
  if ok then return e end
  error(e)
end)
q("seek non-seekable", function()
  local f = io.popen("printf abc", "r")
  local ok, a = pcall(f.seek, f, "set", 0)
  f:close()
  return ok, show(a)
end)
qe("seek fractional offset", function()
  local f = tmp("abcdef")
  local ok, e = pcall(f.seek, f, "set", 1.5)
  f:close()
  if ok then return e end
  error(e)
end)

-- 4. setvbuf
print("== setvbuf ==")
q("setvbuf modes", function()
  local f = tmp()
  local a = f:setvbuf("no")
  local b = f:setvbuf("full")
  local c = f:setvbuf("line")
  local d = f:setvbuf("full", 128)
  f:close()
  return a, b, c, d
end)
qe("setvbuf invalid mode", function()
  local f = tmp()
  local ok, e = pcall(f.setvbuf, f, "half")
  f:close()
  if ok then return e end
  error(e)
end)
qe("setvbuf fractional size", function()
  local f = tmp()
  local ok, e = pcall(f.setvbuf, f, "full", 2.5)
  f:close()
  if ok then return e end
  error(e)
end)
q("unbuffered write is immediately visible", function()
  local path = os.tmpname()
  local f = io.open(path, "w")
  f:setvbuf("no")
  f:write("xy")
  local g = io.open(path, "r")
  local s = g:read("a")
  g:close(); f:close(); os.remove(path)
  return s
end)

-- 5. type/close/flush/input/output
print("== type and file state ==")
q("io.type results", function()
  local f = tmp("x")
  local a = io.type(f)
  f:close()
  local b = io.type(f)
  local c = io.type(42)
  local d = io.type(nil)
  return j(a, b, show(c), show(d), io.type(io.stdin))
end)
q("flush open file", function() local f = tmp(); f:write("x"); local r = f:flush(); f:close(); return r end)
qe("flush closed file", function()
  local f = tmp("x")
  f:close()
  local ok, e = pcall(f.flush, f)
  if ok then return e end
  error(e)
end)
qe("close closed file", function()
  local f = tmp("x")
  f:close()
  local ok, e = pcall(f.close, f)
  if ok then return e end
  error(e)
end)
qe("io.close closed file", function()
  local f = tmp("x")
  io.close(f)
  local ok, e = pcall(io.close, f)
  if ok then return e end
  error(e)
end)
qe("io.close closed default output", function()
  local old = io.output()
  local path = os.tmpname()
  io.output(io.open(path, "w"))
  io.close()
  local ok, e = pcall(io.close)
  io.output(old)
  os.remove(path)
  if ok then return e end
  error(e)
end)
q("io.input(filename) opens for reading", function()
  local path = os.tmpname()
  local f = io.open(path, "w"); f:write("hi\n"); f:close()
  local old = io.input()
  local h = io.input(path)
  local l = h:read("l")
  local same = h == io.input()
  io.input(old)
  h:close()
  os.remove(path)
  return l, same
end)
q("io.output(filename) truncates", function()
  local path = os.tmpname()
  local f = io.open(path, "w"); f:write("0123456789"); f:close()
  local old = io.output()
  local h = io.output(path)
  io.write("ab")
  io.output(old)
  h:close()
  local g = io.open(path, "r"); local s = g:read("a"); g:close()
  os.remove(path)
  return s
end)

-- 6. write/read return values and closed or wrong-mode handles
print("== write and read errors ==")
q("io.write returns the file", function()
  local old = io.output()
  local f = tmp()
  io.output(f)
  local r = io.write("x")
  local same = r == f
  io.output(old)
  f:close()
  return type(r), same
end)
q("write number formats", function()
  local f = tmp()
  f:write(3, "|", 1.5, "|", 1e100, "|", 2^-3, "\n")
  f:seek("set", 0)
  local s = f:read("l")
  f:close()
  return s
end)
qe("write closed file", function()
  local f = tmp("x")
  f:close()
  local ok, e = pcall(f.write, f, "x")
  if ok then return e end
  error(e)
end)
qe("io.write closed default output", function()
  local old = io.output()
  local f = tmp()
  io.output(f)
  io.close(f)
  local ok, e = pcall(io.write, "x")
  io.output(old)
  if ok then return e end
  error(e)
end)
qe("io.read closed default input", function()
  local old = io.input()
  local f = tmp("x")
  io.input(f)
  io.close(f)
  local ok, e = pcall(io.read, "l")
  io.input(old)
  if ok then return e end
  error(e)
end)
q("read on write-only handle", function()
  local path = os.tmpname()
  local f = io.open(path, "w")
  local a, b, c = f:read("l")
  f:close(); os.remove(path)
  return show(a), show(b), show(c)
end)
q("write on read-only handle", function()
  local path = os.tmpname()
  local f = io.open(path, "w"); f:write("x"); f:close()
  local g = io.open(path, "r")
  local a, b, c = g:write("y")
  g:close(); os.remove(path)
  return show(a), show(b), show(c)
end)
print("done")
