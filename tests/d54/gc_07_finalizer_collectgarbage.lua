--! §2.5.1: every collectgarbage option is invalid while a __gc metamethod
--! runs. 5.4 lapi.c returns -1 for each (GCSTPGC is set for the duration) and
--! luaB_collectgarbage turns that into fail, i.e. nil. LuaJIT ran the same
--! options inside a finalizer and answered normally. PUC's suite checks it in
--! gc.lua:699.
local res
local t = setmetatable({}, {__gc = function()
  res = {
    collect = collectgarbage(),
    count = collectgarbage("count"),
    isrunning = collectgarbage("isrunning"),
    step = collectgarbage("step", 0),
    setpause = collectgarbage("setpause", 200),
    setstepmul = collectgarbage("setstepmul", 200),
    gen = collectgarbage("generational"),
    inc = collectgarbage("incremental"),
  }
end})
t = nil
collectgarbage()
for _, k in ipairs{"collect","count","isrunning","step","setpause",
                    "setstepmul","gen","inc"} do
  print(k, res[k])
end
print("after", collectgarbage("isrunning"), type(collectgarbage("count")))
print("ok")
