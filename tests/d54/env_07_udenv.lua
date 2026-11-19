--! modes: B,R
--! 5.4 userdata _ENV: a userdata with __index/__newindex works as an
--! environment (load()'s env may be any value). The hot global loop must
--! compile with the metamethod call recorded (mode B: JIT on vs off; mode R:
--! dump/reload of the test itself). LuaJIT-only because it needs newproxy,
--! hence modes B,R (no PUC reference arm).
local store = {}
local ud = newproxy(true)
local mt = getmetatable(ud)
mt.__index = function(_, k)
  if store[k] then return store[k] end
  if k == "K" then return 2 end
  return "ud:" .. k
end
mt.__newindex = function(_, k, v) store[k] = v * 3 end

print("ud read", load("return x", nil, nil, ud)())
print("ud write", load("w = 2; return w", nil, nil, ud)())
print("ud env", load("return _ENV", nil, nil, ud)() == ud)
print("ud nested", load("return function() return x end", nil, nil, ud)()())
print("ud hot", load("local s = 0 for i = 1, 1000 do s = s + K end return s",
  nil, nil, ud)())

-- A userdata env without __index errors like PUC's generic index path.
local ok, e = pcall(load("return x", nil, nil, newproxy(true)))
print("ud bare", ok, e and (tostring(e):gsub("^.-:%d+: ", "")))
