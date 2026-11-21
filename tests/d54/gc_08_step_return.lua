--! §5 collectgarbage("step"): PUC returns true only when the step finished a
--! collector cycle. A negative parameter only lowers the debt and performs no
--! work (false); after a full collect, step 0, positive and negative all answer
--! false. The test normalises the collector state with "collect" first, so its
--! output does not depend on what the loader or a previous chunk left behind
--! (mode R). Differential against PUC 5.4.9.
local function s(label, v)
  print(label .. " | " .. tostring(v))
end
collectgarbage("collect")
s("after collect step 0", collectgarbage("step", 0))
s("after collect step 100", collectgarbage("step", 100))
s("after collect step -5", collectgarbage("step", -5))
s("after collect step -1", collectgarbage("step", -1))
