--! §2.5.3/§2.5.4: PUC ignores a finalizer that is installed while lua_close
--! runs: luaC_freeallobjects sets GCSTPCLS before separatetobefnz(g, 1), so a
--! setmetatable with __gc inside a closing __gc does not register. A finalizer
--! installed by a __close handler during normal execution is honored.
--! Finalizers only write; the process is closing.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

-- installed before the close: still runs
_G.__gc_close_pre = setmetatable({}, {__gc = function() io.write("pre\n") end})

-- installed during the close: must not run
_G.__gc_close_setter = setmetatable({}, {__gc = function()
  io.write("setter\n")
  setmetatable({}, {__gc = function() io.write("inner-close\n") end})
end})

-- installed by a __close during normal execution: runs on the next cycle
local scope = {}
do
  local x <close> = setmetatable({}, {__close = function()
    scope[#scope+1] = "close"
    setmetatable({}, {__gc = function() scope[#scope+1] = "inner_gc" end})
  end})
end
collectgarbage("collect"); collectgarbage("collect")
p("scope", table.concat(scope, ","))
