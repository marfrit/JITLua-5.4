--! §6.1 collectgarbage reads its second argument only for the options that
--! take one: "step", "setpause", "setstepmul", "generational" and
--! "incremental" (PUC lbaselib.c luaB_collectgarbage). Any value after
--! "collect", "count", "stop", "restart" or "isrunning" is ignored there; this
--! tree checked argument 2 as an integer for every option. Printed: success
--! and result types (the values depend on the collector).
local function p(...)
  local ok, r = pcall(collectgarbage, ...)
  print(select(1, ...), ok, ok and type(r) or (tostring(r):gsub("^[^:]*:%d+: ", "")))
end
p("collect", 1.5)
p("collect", {})
p("count", {})
p("count", "x")
p("isrunning", "x")
p("stop", "x")
p("restart", {})
p("step", "x")
p("step", 1.5)
p("setpause", {})
p("setstepmul", "x")
p("incremental", 1, "x")
p("generational", {})
p("incremental", {})
collectgarbage("incremental")
local ok = 0
for _ = 1, 100 do if pcall(collectgarbage, "count", true) then ok = ok + 1 end end
print("hot count", ok)
print(collectgarbage("isrunning", false))
