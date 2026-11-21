--! modes: A,B
--! timeout: 120
-- Stack overflow: the message handler needs room to run.
--
-- PUC reserves 200 stack slots for the error handler (ldo.c ERRORSTACKSIZE =
-- LUAI_MAXSTACK + 200), so debug.traceback can walk the (huge) stack there.
-- With a smaller reserve the handler's own stack request fails inside the
-- overflow handling and the error becomes "error in error handling" with no
-- frames at all. The location prefix of the message must survive too: at the
-- overflow the violating Lua frame is replaced by a dummy, and the message is
-- built from that frame.
--
-- Prints only counts and booleans: the recursion depth itself is an
-- implementation limit and differs by design (docs/DIFFERENCES.md).

local function numbered (m)
  local n = 0
  for _ in string.gmatch(tostring(m), ":(%d+):") do n = n + 1 end
  return n
end

local function show (tag, m)
  local s = tostring(m)
  print(tag,
	"overflow=" .. tostring(string.find(s, "stack overflow") ~= nil),
	"errerr=" .. tostring(string.find(s, "error in error handling") ~= nil),
	"located=" .. tostring(string.match(s, "^[%w_%.%-%+/%\\]+:%d+: ") ~= nil),
	"numbered=" .. numbered(s))
end

local function rec () rec() end

-- 1. no handler: the message itself.
show("plain", select(2, pcall(rec)))

-- 2. the traceback handler on the overflow.
show("traceback", select(2, xpcall(rec, debug.traceback)))

-- 3. the shape of the PUC suite (errors.lua): a wrapper frame, the recursion
--    writes an upvalue, and the collection is stopped so no finalizer runs
--    without stack space.
local c = 0
local function auxy () c = c + 1; auxy() end
local function g (x)
  collectgarbage("stop")
  auxy()
  collectgarbage("restart")
  return x
end
show("suite", select(2, xpcall(g, debug.traceback, 1)))
collectgarbage("restart")
print("suite ran", c > 0)

-- 4. repeated overflows: the stack must be usable again afterwards.
for i = 1, 3 do pcall(rec) end
show("repeated", select(2, xpcall(rec, debug.traceback)))

-- 5. a handler that needs room for its own recursion: it either finishes and
--    replaces the message, or the overflow handling gives up.
local depth = 0
local function descend ()
  depth = depth + 1
  if depth < 100 then descend() end
end
print("handler", select(2, xpcall(rec, function (m)
  descend()
  return "HANDLER-DEPTH-" .. depth
end)))
