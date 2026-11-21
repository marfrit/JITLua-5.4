--! §2.5 collectgarbage("step", n): n KB of extra debt are worked off before
--! the call returns (PUC 5.4.9 lapi.c LUA_GCSTEP + lgc.c incstep), so a larger
--! n completes a cycle in fewer calls, and a huge n completes it in one.
--! Only these relations are compared; the step counts themselves depend on
--! the collector's work units. Differential against PUC 5.4.9.
collectgarbage("incremental")
-- A fixed pause: under the harness GC-stress prefix (setpause 0) the loop's own
-- allocations already pay for a cycle, in PUC too, and the relation is moot.
collectgarbage("setpause", 200)
local function dosteps(siz)
  collectgarbage()
  local a = {}
  local g = {}  -- the garbage escapes, so the JIT cannot sink it away
  for i = 1, 100 do a[i] = {{}}; g[1] = {} end
  local x = collectgarbage("count")
  local i = 0
  repeat i = i + 1 until collectgarbage("step", siz) or i > 100000
  return i, collectgarbage("count") < x
end
collectgarbage("stop")
local n2, f2 = dosteps(2)
local n10, f10 = dosteps(10)
local nbig, fbig = dosteps(20000)
print("10 fewer than 2", n10 < n2)
print("20000 in one", nbig == 1)
print("freed", f2, f10, fbig)
print("still stopped", not collectgarbage("isrunning"))
collectgarbage("restart")
