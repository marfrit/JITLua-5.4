-- Lua 5.4 _ENV surface in this port: the chunk environment is exposed as a
-- global table alias; globals resolve through the function env (LuaJIT model).
print("env-type", type(_ENV))
print("env-self", _ENV == _G)
print("env-write", (function() _ENV.zz = 42; return zz end)())
_G.zz = nil
local env = { print = print, type = type, x = 7 }
local f = assert(load("return x, type(_ENV), _ENV == nil", "t", "t", env))
print("loaded", f())
_G.zzz = 5
print("global", zzz)
_G.zzz = nil
