--! string.len, math.deg and math.rad are C functions in PUC 5.4.9:
--! debug.getinfo says what = "C" with source "=[C]", a call hook sees a C
--! frame with no line events inside, tracebacks list "[C]: in function",
--! and their argument errors come from luaL_checklstring/luaL_checknumber
--! ("got no value", strings converted, no metamethods). This tree defined
--! them in Lua (LJLIB_LUA): what = "Lua", line events, "got nil", and
--! math.deg("x") raised an arithmetic error. table.move is checked as well
--! (already a C function). The loops at the end run the three functions
--! hot, so the JIT arm records them, with integer, float, string and int64
--! arguments.
for _, n in ipairs{"string.len", "math.deg", "math.rad", "table.move"} do
  local f = load("return " .. n)()
  local i = debug.getinfo(f, "S")
  print(n, i.what, i.source, i.short_src, i.linedefined, i.lastlinedefined)
end

local ev = {}
debug.sethook(function(e, l)
  local i = debug.getinfo(2, "Sn")
  ev[#ev+1] = e .. ":" .. i.what .. ":" .. tostring(i.name) .. (l and (":" .. l) or "")
end, "crl")
local a = string.len("abc"); local b = math.deg(1); local c = math.rad(1)
local d = table.move({1, 2}, 1, 2, 1, {})
debug.sethook()
for i = 1, #ev do
  if not ev[i]:find("sethook") then print((ev[i]:gsub(":%d+$", ":L"))) end
end
print(a, b, c, #d)

local function msg(...)
  local r = table.pack(pcall(...))
  for i = 1, r.n do r[i] = tostring(r[i]) end
  print((table.concat(r, " ", 1, r.n):gsub("[^ ]*:%d+: ", "")))
end
msg(string.len); msg(math.deg); msg(math.rad)
msg(math.deg, "x"); msg(math.rad, {}); msg(string.len, {}); msg(string.len, nil)
msg(math.deg, setmetatable({}, {__mul = function() return 1 end}))
msg(function() return string.len(nil) end)
msg(function() return math.rad(false) end)
print(string.len(12.5), string.len(1), string.len(-0.0), string.len(2^63))
print(string.len("\0\0"), ("abc"):len(), string.len("a", "b"), select("#", string.len("a")))
print(math.deg("1"), math.rad("0x10"), math.deg(2), math.rad(180), math.deg(1 // 1))
print(math.type(math.deg(1)), math.type(math.rad(1)), math.type(string.len("")))
print(math.deg(math.maxinteger), math.rad(math.mininteger), math.deg(1 << 40))
print(math.deg(math.huge), math.rad(-math.huge), math.deg(0/0) ~= math.deg(0/0), 1/math.deg(-0.0))
local co = coroutine.create(function() return string.len(nil) end)
print(coroutine.resume(co))
print((debug.traceback(co):gsub("\n[^\n]*:%d+:[^\n]*", "\n<lua>")))

local s, fs = 0, 0.0
local strs = {"", "a", "abcdef", 123, 1.5}
for i = 1, 300 do
  s = s + string.len(strs[i % #strs + 1])
  fs = fs + math.deg(i) + math.rad(i + 0.5) + math.deg(i * 0.25) + math.rad(-i)
end
print(s, string.format("%.10g", fs))
local big = 1 << 40
local acc = 0.0
for i = 1, 300 do acc = acc + math.deg(big + i) + math.rad(tostring(i)) end
print(string.format("%.10g", acc))
local m = 0
for i = 1, 300 do
  local x = i % 3 == 0 and "ab" or 7
  m = m + string.len(x) + math.type(math.deg(i)):len()
end
print(m)
