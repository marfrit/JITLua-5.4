--! modes: B,R
--! The per-table weakness flag (GCtab.weak) must be exact for every way the
--! __mode key can be written into a metatable that a compiled trace already
--! guards. Each case compiles the index loop while the metatable is strong,
--! changes the weakness, and checks that the entry is (or is not) collected
--! exactly as PUC does. Bounded and observable. Strong->weak (must collect)
--! covers the VM TSETS fast path (existing and new key), TSETV with a computed
--! key, a TDUP constant constructor, rawset, an int-key rehash and
--! debug.setmetatable; weak->strong (must survive) covers nil and non-string
--! values, the deletion path of the flag.
local jit = rawget(_G, "jit")

local function gc2()
  collectgarbage("collect")
  collectgarbage("collect")
end

local function spin(x, LIMIT)
  local n = 0
  while x[1] and n < LIMIT do
    local a = ("garbage"):rep(8)
    n = n + 1
  end
  return n
end

-- Compile strong, mutate, then the weak entry must go away.
local function toweak(label, mutate)
  if jit then jit.flush() end
  local mt = {}
  local x = setmetatable({[1] = {}}, mt)
  spin(x, 2000)                     -- compile while mt is strong
  mutate(mt, x)
  local n = spin(x, 20000)
  gc2()
  assert(x[1] == nil, label .. ": weak entry not collected (n=" .. n .. ")")
  print(label .. ": ok")
end

-- Compile weak, mutate to strong, then the entry must stay alive.
local function tostrong(label, mutate)
  if jit then jit.flush() end
  local mt = {__mode = "kv"}
  local x = setmetatable({[1] = {}}, mt)
  spin(x, 2000)                     -- compile while mt is weak
  mutate(mt, x)
  gc2()
  spin(x, 200)
  assert(x[1] ~= nil, label .. ": strong entry wrongly collected")
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
