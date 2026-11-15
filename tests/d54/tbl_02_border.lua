--! §4.2 '#' border semantics (P1.3b): trailing array nils must not shrink the
--! border. Covers constructors, runtime-built tables, holes and hash spillover.
--! Implementation-defined divergences are in tbl_03_border_divergence.lua.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
p("ctor", #{1,nil,3}, #{1,2,3}, #{1,2,nil,4}, #{nil,2,3}, #{1,nil,3,nil})
p("ctor2", #{1,nil,nil,nil}, #{}, #{nil}, #{1,nil,nil,4}, #{1,2,3,4,5})
p("ctor3", #{nil,nil,3}, #{1,nil,nil,nil,5}, #{1,2,nil,nil,5,6})
p("runtime2", (function() local t = {} t[1]=1 t[2]=2 t[3]=3 return #t end)())
p("runtime3", (function() local t = {} t[3]=3 return #t end)())
p("runtime4", (function() local t = {} for i=1,10 do t[i]=i end t[5]=nil return #t end)())
p("runtime5", (function() local t = {} for i=1,10 do t[i]=i end t[10]=nil return #t end)())
p("hash spill", (function() local t = {} for i=1,40 do t[i]=i end t[20]=nil return #t end)())
p("big sparse", (function() local t = {} t[1]=1 t[1000]=1 return #t end)())
p("concat", pcall(table.concat, {1,nil,3}))
p("unpack", table.unpack({1,nil,3}))
p("vararg", (function() local function f(...) return #{...} end return f(1,nil,3) end)())
p("move", table.concat(table.move({1,nil,3}, 1, 3, 1), ","))
-- JIT hot path must agree.
local r
for i = 1, 500 do r = #{1,nil,3} end
p("jit", r)
for i = 1, 500 do local t = {} t[1]=1 t[3]=3 r = #t end
p("jit runtime", r)
