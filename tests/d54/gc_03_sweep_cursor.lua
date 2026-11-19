--! §2.5.3/§2.5.4: setmetatable(t, mt_with___gc) during a sweep step must not
--! corrupt the GC list. If the sweep cursor rests on the moved object's link
--! (the object was the last one swept alive), the cursor must move to the
--! link that now points at its successor, or the sweep follows the object
--! into the candidate list and skips every object in between (silent heap
--! corruption: live objects stay black, their children are freed).
--! Deterministic repro: step the GC until a step frees something, then mark
--! every table in the just-allocated batch for finalization.
local K, holders, xs = 2000, {}, {}
for i = 1, 300 do holders[i] = {} end
local mt = {__gc = function() end}
collectgarbage("collect")
collectgarbage("setpause", 100)
collectgarbage("setstepmul", 1)
for round = 1, 20 do
  for i = 1, K do xs[i] = {i}; local junk = {i} end
  for step = 1, 300000 do
    local c0 = collectgarbage("count")
    collectgarbage("step", 0)
    if collectgarbage("count") < c0 then        -- first sweep step that freed
      for i = 1, K do setmetatable(xs[i], mt) end  -- one is the cursor object
      break
    end
  end
  for i = 1, 300 do holders[i][1] = {i, {i}} end
  collectgarbage("collect")
  local fill = {}
  for i = 1, 3000 do fill[i] = {"z", "z"} end
  for i = 1, 300 do
    local c = holders[i][1]
    assert(c[1] == i and c[2][1] == i)
  end
end
print("ok")
