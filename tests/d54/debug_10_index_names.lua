--! 5.4 names a value read through a table index (ldebug.c getobjname). A
--! constant integer key that fits OP_GETI (0..255) gives "field 'integer
--! index'"; any other computed key gives "field '?'", unless the key is a
--! string constant that did not fit the instruction's constant operand
--! (OP_GETTABLE/OP_SELF after the RK limit), which gives its text. The name
--! shows in error messages (call, index, arithmetic, length, concatenation)
--! and in debug.getinfo(level, "n"), also inside a call hook. This tree gave
--! no name for any of them, and t[-0] was no integer-key index (the parser
--! did not fold -0, which is the integer 0). Printed: the messages without
--! their position, the name/namewhat a function sees for itself, and the
--! value of the folded -0.
local function msg(f)
  local ok, e = pcall(f)
  print((tostring(e):gsub("^[^:]*:%d+: ", "")))
end
local t = {}
msg(function() t[2]() end)
msg(function() t[0]() end)
msg(function() t[255]() end)
msg(function() t[-0]() end)
msg(function() t[- -1]() end)
msg(function() t[256]() end)
msg(function() t[-1]() end)
msg(function() t[1.5]() end)
msg(function() t[2.0]() end)
msg(function() t[1e300]() end)
msg(function() t[true]() end)
msg(function() local k = "zz"; t[k]() end)
msg(function() local k = 3; t[k]() end)
msg(function() t["x"]() end)
msg(function() t.x.y() end)
msg(function() return t[2] + 1 end)
msg(function() return t[300] + 1 end)
msg(function() local k = 3; return t[k] + 1 end)
msg(function() return t[2].x end)
msg(function() t[2].x = 1 end)
msg(function() t[2] = t[3].a end)
msg(function() return #t[2] end)
msg(function() return t[2]:m() end)
msg(function() return -t[2] end)
msg(function() return t[2] .. "" end)
msg(function() return t[2] < 1 end)
msg(function() local a = t[2]; a() end)
msg(function() local s = "a"; s[1]() end)
msg(function() return ("x")[2]() end)
msg(load("local t = {} ; t[1]()"))

-- Keys past the constant operand of the instruction: 300 string constants
-- come first, so "bbbbb" is loaded into a register (PUC OP_GETTABLE/OP_SELF,
-- here KSTR + TGETV).
do
  local p = {"local t = {}"}
  for i = 1, 300 do p[#p+1] = ("t.k%d = %d"):format(i, i) end
  local s = table.concat(p, "\n")
  msg(load(s .. "\nreturn t.bbbbb + 1"))
  msg(load(s .. "\nt.bbbbb()"))
  msg(load(s .. "\nt:bbbbb()"))
  msg(load(s .. "\nlocal x = t.bbbbb.ccccc"))
end

local function me()
  local i = debug.getinfo(1, "n")
  return tostring(i.name) .. "/" .. tostring(i.namewhat)
end
local u = {me, me, [300] = me}
local k = 1
print(u[2](), u[1](), u[300](), u[k](), u[1.0]())
local w = {u}
print(w[1][2](), (u[2]()))
local h = {}
debug.sethook(function(ev)
  local i = debug.getinfo(2, "n")
  if i.name then h[#h+1] = ev .. ":" .. i.name .. "/" .. i.namewhat end
end, "c")
u[2]()
debug.sethook()
print(table.concat(h, " "))
print(math.type(-0), 1/(-0), math.type(- -0), 1/-(0), -0 == 0, math.type(-0.0), 1/-0.0)
