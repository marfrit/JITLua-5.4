-- GC step quantum: the difference behind tests/corpus/puc54/gengc.lua line 122.
-- Not part of any corpus: it prints what each implementation does, PUC 5.4.9 and
-- ours differ.  Run with both binaries, no flags:
--   tests/ref/bin/lua54ref tests/lib/gc-step-quantum-repro.lua
--   src/luajit -joff tests/lib/gc-step-quantum-repro.lua
-- gengc.lua's last block stores a fresh table in an all-weak table and asserts
-- after three collectgarbage("step", 0) calls that the entry is gone.  PUC's
-- basic step is much larger than LuaJIT's, so it dies after one step there.
local function probe(gen, stepmul)
  collectgarbage("setstepmul", stepmul)
  if gen then collectgarbage("generational") else collectgarbage("incremental") end
  local t = setmetatable({}, {__mode = "kv"})
  collectgarbage()                 -- t is old/black and empty
  t[1] = {10}                      -- only the weak entry keeps this table alive
  local n, done = 0, nil
  while t[1] ~= nil and n < 200 do
    n = n + 1
    if collectgarbage("step", 0) and done == nil then done = n end
  end
  print(("gen=%-5s stepmul=%-6d basic steps to clear the weak entry: %-4s" ..
         " step that reported a finished cycle: %s"):format(
          tostring(gen), stepmul, n, tostring(done)))
end
probe(false, 200)      -- incremental, default quantum
probe(true, 200)       -- "generational": ours stays incremental, PUC does a minor collection
probe(false, 20000)    -- with a bigger quantum ours clears the entry in one step, like PUC
