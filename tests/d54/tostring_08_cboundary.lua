--! §5.4 A __tostring is called as a normal call from the tostring() fast
--! function, so it sits behind a C-call boundary: a yield inside it is an
--! error (PUC 5.4.9 luaL_tolstring does the same through luaL_callmeta), the
--! caller seen from the metamethod is a C function, and an error raised
--! inside the metamethod reports the metamethod itself. Mode A compares this
--! with PUC 5.4.9; mode B compares the interpreter with compiled code (the
--! loop around the conversion is hot, so a trace that followed the call with
--! a continuation frame of its own would have to keep both properties).
local function strip(e) return (tostring(e):gsub("^.-:%d+: ", "")) end

-- 1. yield directly inside __tostring: error, and the coroutine is dead.
local c1 = coroutine.create(function()
  local t = setmetatable({}, { __tostring = function() coroutine.yield("Y") end })
  return tostring(t)
end)
local ok1, r1 = coroutine.resume(c1)
print("yield-direct", ok1, strip(r1), coroutine.status(c1))

-- 2. yield one Lua level deeper (the metamethod calls a function that yields).
local function deep() return coroutine.yield("Y") end
local c2 = coroutine.create(function()
  local t = setmetatable({}, { __tostring = function() return deep() end })
  return "x" .. tostring(t)
end)
local ok2, r2 = coroutine.resume(c2)
print("yield-deep", ok2, strip(r2), coroutine.status(c2))

-- 3. the same conversion paths: print() and string.format("%s").
local c3 = coroutine.create(function()
  local t = setmetatable({}, { __tostring = function() coroutine.yield("Y") end })
  print(t)
  return 1
end)
local ok3, r3 = coroutine.resume(c3)
print("yield-print", ok3, strip(r3))
local c4 = coroutine.create(function()
  local t = setmetatable({}, { __tostring = function() coroutine.yield("Y") end })
  return string.format("%s", t)
end)
local ok4, r4 = coroutine.resume(c4)
print("yield-format", ok4, strip(r4))

-- 4. the frame above the metamethod is a C function (a continuation frame
-- below the metamethod, as the interpreter uses for __add, would show the
-- calling Lua line instead).
local t4 = setmetatable({}, { __tostring = function()
  local l1, l2 = debug.getinfo(1, "S"), debug.getinfo(2, "S")
  local l3 = debug.getinfo(3, "S")
  return (l1 and l1.what or "-") .. "/" .. (l2 and l2.what or "-") .. "/"
	 .. (l3 and l3.what or "-")
end })
local a = 0
for i = 1, 1200 do a = a + #tostring(t4) end   -- hot: compiled as well
print("frame-whats", tostring(t4), a > 0)

-- 5. an error raised inside the metamethod is reported at the metamethod.
local t5 = setmetatable({}, { __tostring = function() error("boom") end })
local b = 0
for i = 1, 1200 do
  local ok, e = pcall(tostring, t5)
  if not ok then b = b + 1; if i == 1200 then print("mm-error", strip(e)) end end
end
print("mm-error-count", b)

-- 6. the frame chain above the metamethod: metamethod (Lua) -> conversion
-- (C) -> the calling Lua line. An error raised at level 3 is attributed to
-- the caller of tostring(); a continuation frame below the metamethod would
-- make it the caller of the metamethod instead.
local t6 = setmetatable({}, { __tostring = function() error("L3", 3) end })
local ok6, e6 = pcall(function() return tostring(t6) end)
print("level3", ok6, e6:gsub("^.*[/\\]", ""):gsub("^tostring_08_cboundary", "T"))
