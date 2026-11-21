--! The user stop flag survives "collect" and an explicit step (5.4 lapi.c
--! LUA_GCCOLLECT/LUA_GCSTEP with g->gcstp, lgc.c luaC_step does nothing while
--! gcstp is set): after collectgarbage("stop") no automatic collection runs,
--! however the collector was driven by hand meanwhile. A step of n KB while
--! stopped still does n KB of work (lapi.c clears gcstp for the step).
--! The heap figures are compared as coarse booleans only. The test runs in
--! incremental mode: the standalone PUC interpreter starts generational, where
--! a step never reports the end of a cycle (lgc.c genstep keeps the state).
local function kb() return collectgarbage("count") end
-- the tables escape into `sink`, so a compiled loop allocates them as well
local sink = {}
local function garbage(n) for i = 1, n do sink[1] = {} end end

collectgarbage("incremental")
collectgarbage(); collectgarbage()
collectgarbage("stop")
local before = kb()
garbage(200000)
print("stop: heap grows", kb() - before > 5000, collectgarbage("isrunning"))

collectgarbage("restart"); collectgarbage(); collectgarbage("stop")
collectgarbage()   -- a full collection does not restart the collector
before = kb()
garbage(200000)
print("stop+collect: heap grows", kb() - before > 5000, collectgarbage("isrunning"))

collectgarbage("restart"); collectgarbage(); collectgarbage("stop")
collectgarbage("step", 0)   -- neither does a basic step
before = kb()
garbage(200000)
print("stop+step(0): heap grows", kb() - before > 5000, collectgarbage("isrunning"))

-- an explicit large step frees the garbage although the collector is stopped
collectgarbage("restart"); collectgarbage(); collectgarbage("stop")
garbage(200000)
before = kb()
local r
for i = 1, 20 do r = collectgarbage("step", 1000); if r then break end end
print("stop+step(1000): cycle ends", r, before - kb() > 5000, collectgarbage("isrunning"))
before = kb()
garbage(200000)
print("after the steps: heap grows", kb() - before > 5000, collectgarbage("isrunning"))

collectgarbage("restart")
print("restarted", collectgarbage("isrunning"))
