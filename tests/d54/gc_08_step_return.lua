--! §5 collectgarbage("step"): PUC returns true only when the step finished a
--! collector cycle. A negative parameter only lowers the debt and performs no
--! work (false). The file runs in incremental mode: the standalone PUC starts
--! generational, which is only a mode flag here (docs/DIFFERENCES.md). A
--! positive step works its debt off, so after a full collect step 100 ends the
--! small cycle; how many basic steps (step 0) a cycle takes is the collector's
--! work unit (IMPL-DEFINED), so only "step 0 ends a cycle eventually" is printed.
--! The test normalises the collector state with "collect" first, so its
--! output does not depend on what the loader or a previous chunk left behind
--! (mode R). Differential against PUC 5.4.9.
local function s(label, v)
  print(label .. " | " .. tostring(v))
end
collectgarbage("incremental")
collectgarbage("collect")
do
  local n = 0
  repeat n = n + 1 until collectgarbage("step", 0) or n > 100000
  s("after collect step 0 ends a cycle", n <= 100000)
end
collectgarbage("collect")
s("after collect step 100", collectgarbage("step", 100))
s("after collect step -5", collectgarbage("step", -5))
s("after collect step -1", collectgarbage("step", -1))
