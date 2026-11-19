--! modes: B,R
--! Every way the __mode key can be written into a metatable that a compiled
--! trace already guards must be seen by that trace. Each case compiles the
--! index loop while the metatable is strong, changes the weakness, and runs
--! the same loop again: it allocates, so the collector runs inside it, and
--! the weak entry has to disappear before the bound. Nothing collects on the
--! loop's behalf; a trace that keeps running without noticing the change
--! holds the entry in a stack slot and the case fails (bounded, no hang).
--! Strong->weak covers the VM TSETS fast path (existing and new key), TSETV
--! with a computed key, a TDUP constant constructor, rawset, an int-key
--! rehash and debug.setmetatable; weak->strong (must survive) covers nil and
--! non-string values and a new metatable.
-- The bounds in this test are sized for a collector pause of 200. Pin it, so
-- the result does not depend on the default GC policy; a lower pause (the
-- harness's GC-stress arm) is kept.
do
  local prev = collectgarbage("setpause", 200)
  if prev < 200 then collectgarbage("setpause", prev) end
end
local jit = rawget(_G, "jit")
local Last                        -- keeps the loop's allocation live

local function gc2()
  collectgarbage("collect")
  collectgarbage("collect")
end

local function spin(x, LIMIT)
  local n = 0
  while x[1] and n < LIMIT do
    -- A new string each time, and it stays live: an interned constant string
    -- allocates nothing and would never run the collector.
    Last = ("garbage"):rep(8) .. n
    n = n + 1
  end
  return n
end

-- Compile strong, mutate, then the loop itself must see the entry go away.
local function toweak(label, mutate)
  if jit then jit.flush() end
  -- Start every case from a finished collection. Each case ends at the
  -- atomic phase of a cycle; without this the next one starts in its sweep
  -- and the cycle length can double from case to case, up to the bound.
  gc2()
  local mt = {}
  local x = setmetatable({[1] = {}}, mt)
  spin(x, 2000)                     -- compile while mt is strong
  mutate(mt, x)
  local LIMIT = 20000
  local n = spin(x, LIMIT)
  assert(x[1] == nil and n < LIMIT,
         label .. ": weak entry not collected (n=" .. n .. ")")
  print(label .. ": ok")
end

-- Compile weak, mutate to strong, then the entry must stay alive through
-- collections inside and outside the loop.
local function tostrong(label, mutate)
  if jit then jit.flush() end
  local mt = {__mode = "kv"}
  local x = setmetatable({}, mt)
  local keep = {}
  x[1] = keep                       -- alive while the table is still weak
  spin(x, 2000)                     -- compile while mt is weak
  mutate(mt, x)
  keep = nil
  gc2()
  local n = spin(x, 5000)
  assert(x[1] ~= nil and n == 5000, label .. ": strong entry wrongly collected")
  print(label .. ": ok")
end

-- TSETS, new key.
toweak("tsets-new", function(mt) mt.__mode = "kv" end)

-- TSETS, existing key (the key exists with a non-string, strong value).
toweak("tsets-existing", function(mt) mt.__mode = 42; mt.__mode = "kv" end)

-- TSETV with a computed key.
toweak("tsetv", function(mt) local k = "__" .. "mode"; mt[k] = "kv" end)

-- rawset (the C lua_rawset path).
toweak("rawset", function(mt) rawset(mt, "__mode", "kv") end)

-- constant table constructor via TDUP, installed with setmetatable.
toweak("tdup", function(mt, x) setmetatable(x, {__mode = "kv", tag = 1}) end)

-- debug.setmetatable with a TDUP constant constructor.
toweak("debug-setmt", function(mt, x) debug.setmetatable(x, {__mode = "kv"}) end)

-- int-key stores (TSETB/TSETM/rehash) must not corrupt the flag, and a
-- following string-key store must still be seen.
toweak("rehash", function(mt)
  local i
  for i = 1, 40 do mt[i] = i end
  mt.__mode = "kv"
end)

-- weak -> strong: delete __mode.
tostrong("strong-nil", function(mt) mt.__mode = nil end)

-- weak -> strong: non-string value.
tostrong("strong-nonstr", function(mt) mt.__mode = 42 end)

-- weak -> strong: a new metatable without __mode.
tostrong("strong-setmt", function(mt, x) setmetatable(x, {tag = 2}) end)

print("ok")
