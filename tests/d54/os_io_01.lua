--! §4.2 os/io library 5.4 exactness (harness forces TZ=UTC, LC_ALL=C).
--! Resilient: each check is protected so one failure doesn't hide the rest.
--! NOTE: calls are deliberately NOT tail calls -- LuaJIT destroys the caller
--! frame on a tail call, which breaks error-message function-name resolution
--! (tracked separately in err_02_tailname.lua).
local function p(label, f)
  local ok, a, b, c = pcall(f)
  if ok then
    print(label .. " | " .. tostring(a) .. " | " .. tostring(b) .. " | " .. tostring(c))
  else
    print(label .. " | ERR | " .. tostring(a):gsub("^.-:%d+: ", ""))
  end
end
p("time table", function()
  local r = os.time({ year = 2000, month = 1, day = 1, hour = 12, min = 0, sec = 0, isdst = false })
  return r
end)
p("time table defaults", function() local r = os.time({ year = 2000, month = 1, day = 1 }) return r end)
p("time missing field", function() local r = os.time({ year = 2000, month = 1 }) return r end)
p("time bad month", function() local r = os.time({ year = 2000, month = 13, day = 1 }) return r end)
p("time bad type", function() local r = os.time("x") return r end)
p("time type", function() local r = os.time({ year = 2000, month = 1, day = 1 }) return math.type(r) end)
p("date utc", function() local r = os.date("!%Y-%m-%dT%H:%M:%S", 946728000) return r end)
p("date fields", function()
  local t = os.date("!*t", 946728000)
  return t.year, t.month, t.day
end)
p("date hour", function()
  local t = os.date("!*t", 946728000)
  return t.hour, t.min, t.sec
end)
p("date wday yday", function()
  local t = os.date("!*t", 946728000)
  return t.wday, t.yday, tostring(t.isdst)
end)
p("date roundtrip", function() local r = os.time(os.date("!*t", 946728000)) return r end)
p("date no arg", function() local r = type(os.date()) return r end)
p("date bad fmt", function() local r = os.date("%Q", 0) return r end)
p("date bad fmt2", function() local r = os.date("%", 0) return r end)
p("date E modifier", function() local r = os.date("!%Ec", 946728000) return type(r) end)
p("difftime", function() local r = os.difftime(100, 50) return r, math.type(r) end)
p("difftime one arg", function() local r = os.difftime(100) return r end)
p("clock", function() local r = type(os.clock()) return r end)
p("getenv", function() local r = type(os.getenv("PATH")) return r end)
p("tmpname", function() local n = os.tmpname(); os.remove(n) return type(n) end)
p("remove missing", function() local a, b, c = os.remove("/nonexistent-lj54-test-file") return a, b, c end)
p("rename missing", function() local a, b, c = os.rename("/nonexistent-lj54-a", "/nonexistent-lj54-b") return a, b, c end)
p("exit type", function() local r = type(os.exit) return r end)
p("setlocale", function() local r = type(os.setlocale("C")) return r end)
-- io
p("io type", function() local r = type(io.read) return r, type(io.lines) end)
p("io write ret", function() local r = io.write("") return type(r), r == io.output() end)
p("io stderr", function() local r = type(io.stderr) return r end)
p("io open missing", function() local a, b, c = io.open("/nonexistent-lj54-test-file", "r") return a, b, c end)
p("io open bad mode", function() local r = io.open("/tmp", "q") return r end)
p("io open bad mode2", function() local r = io.open("/tmp", "rq") return r end)
p("io open ok mode", function()
  local f = io.open("/tmp/lj54-test-mode", "w+b")
  if f then f:close(); os.remove("/tmp/lj54-test-mode") end
  return f ~= nil
end)
p("io lines missing", function() local r = io.lines("/nonexistent-lj54-test-file") return r end)
p("io read num fmt", function()
  local f = io.tmpfile()
  f:write("42 3.5 abc")
  f:seek("set", 0)
  local a = f:read("n")
  local b = f:read("n")
  local c = f:read("n")
  f:close()
  return a, b, c
end)
p("io read bad fmt", function()
  local f = io.tmpfile()
  local ok, err = pcall(f.read, f, "q")
  f:close()
  return ok, tostring(err):gsub("^.-:%d+: ", "")
end)
p("io seek", function()
  local f = io.tmpfile()
  f:write("abcdef")
  local pos = f:seek("set", 2)
  local s = f:read(2)
  f:close()
  return pos, s
end)
p("io lines formats", function()
  local f = io.tmpfile()
  f:write("1\n2\n")
  f:seek("set", 0)
  local t = {}
  for l in f:lines("l") do t[#t + 1] = l end
  f:close()
  return table.concat(t, ",")
end)
p("file write ret", function()
  local f = io.tmpfile()
  local r = f:write("x")
  f:close()
  return r == f
end)
