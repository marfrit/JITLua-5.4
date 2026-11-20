--! §2.5.1 collectgarbage("isrunning") and the user stop flag: 5.4 keeps the
--! flag across an explicit step and across "collect" (lapi.c saves g->gcstp
--! around a step and luaC_fullgc ignores it), so "isrunning" stays false.
--! LuaJIT derived "isrunning" from the GC threshold and a step made the
--! collector run again: after collectgarbage("stop") a step answered true.
--! PUC's suite checks this in gc.lua:209.
collectgarbage("stop")
print("stopped", collectgarbage("isrunning"))
print("step0", collectgarbage("step", 0))
print("still stopped", collectgarbage("isrunning"))
print("collect", collectgarbage())
print("still stopped", collectgarbage("isrunning"))
collectgarbage("restart")
print("restarted", collectgarbage("isrunning"))
print("step", collectgarbage("step", 0))
print("ok")
