--! §2.7 io: a value is a file handle when its metatable is the current
--! registry["FILE*"] (PUC liolib.c tolstream/tofile with luaL_checkudata,
--! io_type with luaL_testudata). This tree accepted every io handle by its
--! userdata kind, so a handle made while the entry was nil, or whose
--! metatable was replaced, or one left behind when the entry was replaced,
--! still read, wrote, closed and was "file" for io.type. The default
--! input/output of io.read/io.write is not checked (getiofile), but
--! io.close() and io.lines() check it (tofile). Printed: results and errors,
--! also from loops compiled under -jon whose handle or registry entry
--! changes in the middle.
local reg = debug.getregistry()
local FMT = reg["FILE*"]
local M = FMT.__index
local function norm(m) return (tostring(m):gsub("^[^:]*:%d+: ", "")) end
local function p(label, f, ...)
  local r = table.pack(pcall(f, ...))
  local t = {}
  for i = 2, r.n do t[#t + 1] = type(r[i]) == "userdata" and "<handle>" or norm(r[i]) end
  print(label, r[1], table.concat(t, " / "))
end
local function open(mode) return assert(io.open("/dev/null", mode or "r")) end

-- A handle without a metatable.
reg["FILE*"] = nil
local bare = open()
reg["FILE*"] = FMT
print("bare mt", getmetatable(bare))
p("bare type", io.type, bare)
p("bare read", M.read, bare)
p("bare lines", M.lines, bare)
p("bare seek", M.seek, bare)
p("bare setvbuf", M.setvbuf, bare, "no")
p("bare flush", M.flush, bare)
p("bare tostring", FMT.__tostring, bare)
p("bare close", io.close, bare)
p("bare input", io.input, bare)
p("bare output", io.output, bare)

-- A handle whose metatable is replaced, then restored.
local h = open("w")
debug.setmetatable(h, {__index = M, __name = "notfile"})
p("replaced type", io.type, h)
p("replaced write", M.write, h, "x")
p("replaced method", function() return h:write("x") end)
p("replaced close", io.close, h)
debug.setmetatable(h, FMT)
p("restored type", io.type, h)
p("restored write", function() return h:write("x") end)

-- The registry entry replaced: new handles get the new table; the old
-- ones are no longer files, the new ones are.
local other = {__index = M, __name = "other", __gc = FMT.__gc, __close = FMT.__close}
reg["FILE*"] = other
local n = open("w")
p("new under other", io.type, n)
p("new write", function() return n:write("y") end)
p("old under other", io.type, h)
p("old write", M.write, h, "y")
p("stdout under other", io.type, io.stdout)
p("io.write default", io.write, "")
p("io.close default", io.close)
p("io.lines default", io.lines)
p("io.read default", io.read, 0)
reg["FILE*"] = FMT
p("new back", io.type, n)
p("old back", io.type, h)
debug.setmetatable(n, FMT)
p("close n", io.close, n)
p("close h", io.close, h)
p("closed type", io.type, h)
p("closed write", M.write, h, "z")
p("closed tostring", FMT.__tostring, h)

-- Compiled loops: the handle's metatable, and the registry entry, change
-- after the loop is hot.
local w = open("w")
local write = M.write
local ok, bad, last = 0, 0, nil
for i = 1, 300 do
  if i == 150 then debug.setmetatable(w, {__index = M}) end
  if i == 200 then debug.setmetatable(w, FMT) end
  local s, e = pcall(write, w, "a", 1)
  if s then ok = ok + 1 else bad = bad + 1; last = norm(e) end
end
print("hot mt", ok, bad, last)
ok, bad, last = 0, 0, nil
for i = 1, 300 do
  if i == 150 then reg["FILE*"] = other end
  if i == 200 then reg["FILE*"] = FMT end
  local s, e = pcall(write, w, "b")
  if s then ok = ok + 1 else bad = bad + 1; last = norm(e) end
end
print("hot registry", ok, bad, last)
ok, bad, last = 0, 0, nil
for i = 1, 300 do
  if i == 150 then reg["FILE*"] = other end
  if i == 200 then reg["FILE*"] = FMT end
  local s, e = pcall(function() return w:flush() end)
  if s then ok = ok + 1 else bad = bad + 1; last = norm(e) end
end
print("hot flush", ok, bad, last)
ok = 0
for i = 1, 300 do
  if i == 150 then debug.setmetatable(io.stdout, {__index = M}) end
  if i == 200 then debug.setmetatable(io.stdout, FMT) end
  if pcall(io.write, "") then ok = ok + 1 end
end
print("hot default", ok)
w:close()
