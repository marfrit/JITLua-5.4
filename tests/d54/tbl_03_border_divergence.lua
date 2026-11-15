--! §4.2 IMPLEMENTATION-DEFINED divergence (not a bug): for tables with holes
--! the Lua 5.4 manual allows ANY border. PUC's luaH_getn uses an 'alimit' hint
--! tied to its array-growth policy; LuaJIT grows the array differently, so a
--! runtime-built sparse table can report a different (equally legal) border.
--! Constructors are normalized to match PUC (see tbl_02_border.lua).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("runtime sparse", (function() local t = {} t[1]=1 t[3]=3 return #t end)())
p("runtime sparse2", (function() local t = {} t[2]=2 t[4]=4 return #t end)())
p("runtime hole", (function() local t = {} for i=1,8 do t[i]=i end t[4]=nil return #t end)())
p("runtime tail nil", (function() local t = {} for i=1,8 do t[i]=i end t[8]=nil return #t end)())
-- Both answers below are legal borders; recorded to make the divergence visible.
p("legal borders", (function()
  local t = {} t[1]=1 t[3]=3
  local n = #t
  return n == 1 or n == 3, t[n] ~= nil or n == 0
end)())
