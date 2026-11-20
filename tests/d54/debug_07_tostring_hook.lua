--! §6.10 (debug.sethook), §6.1 (tostring): the call and return events around
--! tostring. The function is entered and left once whether it converts the
--! value itself or calls a __tostring metamethod; the metamethod has its own
--! pair of events in between. Fixed output only.
local ev = {}
local function hook(e)
  local i = debug.getinfo(2, "nS")
  ev[#ev+1] = e .. ":" .. (i.name or "?") .. "/" .. i.what
end
local function events(v)
  ev = {}
  debug.sethook(hook, "cr")
  local s = tostring(v)
  debug.sethook()
  -- Drop the events of sethook itself.
  table.remove(ev, 1); table.remove(ev)
  print(s, table.concat(ev, " "))
end

local t = setmetatable({}, {__tostring = function() ev[#ev+1] = "mm"; return "s" end})
local n = setmetatable({}, {__tostring = function() ev[#ev+1] = "mm"; return 42 end})
events(12)
events("str")
events(t)
events(n)
-- The same from a loop that gets hot: every round has the same events.
local seen, same = nil, true
for i = 1, 200 do
  ev = {}
  debug.sethook(hook, "cr")
  local s = tostring(t)
  debug.sethook()
  local line = table.concat(ev, " ")
  if seen == nil then seen = line elseif seen ~= line then same = false end
end
print(same, seen)
